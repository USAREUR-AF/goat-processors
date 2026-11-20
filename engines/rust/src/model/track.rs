//! correlate.md Track estimate: one constant-velocity Kalman filter per axis
//! (prediction, position and velocity updates, likelihood terms). Every
//! function here is pure: it takes a state and returns a new one.

/// One axis of the constant-velocity filter.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Axis {
    pub p: f64,
    pub v: f64,
    pub pp: f64,
    pub pv: f64,
    pub vv: f64,
}

impl Axis {
    /// First report, with `pp = ce²`.
    pub fn first(z: f64, vel: Option<f64>, ce: f64, vel_sigma_ms: f64, unknown_vel_ms: f64) -> Axis {
        Axis::first_with_variance(z, vel, ce * ce, vel_sigma_ms, unknown_vel_ms)
    }

    /// First report, with `pp = r`, that axis's measurement variance
    /// (correlate.md 0.8 Track estimate, First report).
    pub fn first_with_variance(z: f64, vel: Option<f64>, r: f64, vel_sigma_ms: f64, unknown_vel_ms: f64) -> Axis {
        Axis {
            p: z,
            v: vel.unwrap_or(0.0),
            pp: r,
            pv: 0.0,
            vv: match vel {
                Some(_) => vel_sigma_ms * vel_sigma_ms,
                None => unknown_vel_ms * unknown_vel_ms,
            },
        }
    }

    /// Step 1, predict by `dt` seconds with process noise `q`.
    pub fn predict(&self, dt: f64, q: f64) -> Axis {
        let Axis { p, v, pp, pv, vv } = *self;
        Axis {
            p: p + v * dt,
            v,
            pp: pp + 2.0 * dt * pv + dt * dt * vv + q * dt.powi(4) / 4.0,
            pv: pv + dt * vv + q * dt.powi(3) / 2.0,
            vv: vv + q * dt * dt,
        }
    }

    /// Step 2, position update with measurement `z` and variance `r`; also
    /// returns the innovation.
    pub fn update_position(&self, z: f64, r: f64) -> (Axis, Innovation) {
        let Axis { p, v, pp, pv, vv } = *self;
        let s = pp + r;
        let k1 = pp / s;
        let k2 = pv / s;
        let y = z - p;
        (Axis { p: p + k1 * y, v: v + k2 * y, pp: (1.0 - k1) * pp, pv: (1.0 - k1) * pv, vv: vv - k2 * pv }, Innovation { y, s })
    }

    /// Step 3, velocity update with measurement `z` and variance `r`; also
    /// returns the innovation.
    pub fn update_velocity(&self, z: f64, r: f64) -> (Axis, Innovation) {
        let Axis { p, v, pp, pv, vv } = *self;
        let s = vv + r;
        let k1 = pv / s;
        let k2 = vv / s;
        let y = z - v;
        (Axis { p: p + k1 * y, v: v + k2 * y, pp: pp - k1 * pv, pv: (1.0 - k2) * pv, vv: (1.0 - k2) * vv }, Innovation { y, s })
    }

    /// `blend(w1, w2)` of two axis states (spec: Two-model filter, step 1).
    pub fn blend(w1: f64, a1: &Axis, w2: f64, a2: &Axis) -> Axis {
        let p = w1 * a1.p + w2 * a2.p;
        let v = w1 * a1.v + w2 * a2.v;
        let (d1, e1, d2, e2) = (a1.p - p, a1.v - v, a2.p - p, a2.v - v);
        Axis {
            p,
            v,
            pp: w1 * (a1.pp + d1 * d1) + w2 * (a2.pp + d2 * d2),
            pv: w1 * (a1.pv + d1 * e1) + w2 * (a2.pv + d2 * e2),
            vv: w1 * (a1.vv + e1 * e1) + w2 * (a2.vv + e2 * e2),
        }
    }

    pub fn as_list(&self) -> [f64; 5] {
        [self.p, self.v, self.pp, self.pv, self.vv]
    }
}

/// Innovation `y` and its variance `s` of one scalar update.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Innovation {
    pub y: f64,
    pub s: f64,
}

impl Innovation {
    /// The likelihood term `y*y/s + ln(s)`.
    pub fn term(&self) -> f64 {
        self.y * self.y / self.s + self.s.ln()
    }
}

/// The measurements of one report, in the plane.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Measurement {
    /// `(east, north)` position, with its measurement variance per axis
    /// `(r_east, r_north)` (correlate.md Track estimate, Measurement variance).
    pub pos: (f64, f64),
    pub r_pos: (f64, f64),
    /// `(ve, vn)` when the report has `course` and `speed_ms`, with variance
    /// `r_vel = vel_sigma_ms²`.
    pub vel: Option<(f64, f64)>,
    pub r_vel: f64,
}

/// Both axes of one constant-velocity filter.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Model {
    pub east: Axis,
    pub north: Axis,
}

impl Model {
    /// Track estimate step 1 on both axes.
    pub fn predict(&self, dt: f64, q: f64) -> Model {
        Model { east: self.east.predict(dt, q), north: self.north.predict(dt, q) }
    }

    /// Track estimate steps 1 to 3 for a later report. Also returns `g`, the
    /// sum from 0 of the likelihood terms in the order east position, north
    /// position, east velocity, north velocity (Two-model filter, step 3).
    pub fn step(&self, dt: f64, q: f64, m: &Measurement) -> (Model, f64) {
        let predicted = self.predict(dt, q);
        let (mut east, ie) = predicted.east.update_position(m.pos.0, m.r_pos.0);
        let (mut north, in_) = predicted.north.update_position(m.pos.1, m.r_pos.1);
        let mut g = 0.0 + ie.term() + in_.term();
        if let Some((ve, vn)) = m.vel {
            let (e, iev) = east.update_velocity(ve, m.r_vel);
            let (n, inv) = north.update_velocity(vn, m.r_vel);
            east = e;
            north = n;
            g = g + iev.term() + inv.term();
        }
        (Model { east, north }, g)
    }

    /// `blend(w1, w2)` of two models, per axis.
    pub fn blend(w1: f64, m1: &Model, w2: f64, m2: &Model) -> Model {
        Model { east: Axis::blend(w1, &m1.east, w2, &m2.east), north: Axis::blend(w1, &m1.north, w2, &m2.north) }
    }
}
