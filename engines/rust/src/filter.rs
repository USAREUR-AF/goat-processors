//! Frame, track estimate and two-model filter (spec: Frame, Track estimate,
//! Two-model filter).

pub const R: f64 = 6371008.8;

pub fn rad(x: f64) -> f64 {
    x * std::f64::consts::PI / 180.0
}

pub fn deg(x: f64) -> f64 {
    x * 180.0 / std::f64::consts::PI
}

/// Brings a longitude difference or longitude into (-180, 180].
pub fn wrap180(mut x: f64) -> f64 {
    while x > 180.0 {
        x -= 360.0;
    }
    while x <= -180.0 {
        x += 360.0;
    }
    x
}

/// The local plane, meters east and north of the reference point.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Frame {
    pub lat0: f64,
    pub lon0: f64,
}

impl Frame {
    /// `(east, north)` of a position in degrees.
    pub fn to_plane(&self, lat: f64, lon: f64) -> (f64, f64) {
        let dlon = wrap180(lon - self.lon0);
        let east = R * rad(dlon) * rad(self.lat0).cos();
        let north = R * rad(lat - self.lat0);
        (east, north)
    }

    /// `(lat, lon)` in degrees of a plane position.
    pub fn to_degrees(&self, east: f64, north: f64) -> (f64, f64) {
        let lat = self.lat0 + deg(north / R);
        let lon = self.lon0 + deg(east / (R * rad(self.lat0).cos()));
        (lat, wrap180(lon))
    }
}

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
    /// First report.
    pub fn first(z: f64, vel: Option<f64>, ce: f64, vel_sigma_ms: f64, unknown_vel_ms: f64) -> Axis {
        Axis {
            p: z,
            v: vel.unwrap_or(0.0),
            pp: ce * ce,
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
    /// `(east, north)` position, with variance `r_pos = ce²`.
    pub pos: (f64, f64),
    pub r_pos: f64,
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
        let (mut east, ie) = predicted.east.update_position(m.pos.0, m.r_pos);
        let (mut north, in_) = predicted.north.update_position(m.pos.1, m.r_pos);
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

/// The two models of Two-model filter: index 0 is `quiet` (model 1), index 1
/// is `maneuver` (model 2), with mode probabilities `mu`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TwoModel {
    pub models: [Model; 2],
    pub mu: [f64; 2],
}

/// What one later report gives for the trace: `lambda` and the new `mu`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModeUpdate {
    pub lambda: [f64; 2],
    pub mu: [f64; 2],
}

/// Switching over `dt` seconds: `t[i][j]`, the probability of model `j` at
/// the end of `dt` given model `i` at its start.
fn switching(a: f64, b: f64, dt: f64) -> [[f64; 2]; 2] {
    let s = a + b;
    let l = (1.0 - s).powf(dt);
    let t12 = a / s * (1.0 - l);
    let t21 = b / s * (1.0 - l);
    [[1.0 - t12, t12], [t21, 1.0 - t21]]
}

impl TwoModel {
    /// First report: both models the first-report filter, `mu1 = b / s`,
    /// `mu2 = a / s`.
    pub fn first(filter: Model, a: f64, b: f64) -> TwoModel {
        let s = a + b;
        TwoModel { models: [filter, filter], mu: [b / s, a / s] }
    }

    /// The entity's filter: `blend(mu1, mu2)` of the two models (step 5).
    pub fn combined(&self) -> Model {
        Model::blend(self.mu[0], &self.models[0], self.mu[1], &self.models[1])
    }

    /// Prediction: each model by its own `q`, combined with the current `mu`.
    pub fn predict(&self, dt: f64, q: [f64; 2]) -> Model {
        let p1 = self.models[0].predict(dt, q[0]);
        let p2 = self.models[1].predict(dt, q[1]);
        Model::blend(self.mu[0], &p1, self.mu[1], &p2)
    }

    /// A later report, steps 1 to 4. `q` holds `[q1, q2]`; `a`, `b` are
    /// `p_enter`, `p_leave`.
    pub fn step(&self, dt: f64, q: [f64; 2], a: f64, b: f64, m: &Measurement) -> (TwoModel, ModeUpdate) {
        let t = switching(a, b, dt);
        let [mu1, mu2] = self.mu;
        let [m1, m2] = &self.models;

        // 1. Mixing, both from the model states before mixing.
        let c = [t[0][0] * mu1 + t[1][0] * mu2, t[0][1] * mu1 + t[1][1] * mu2];
        let mixed: [Model; 2] = std::array::from_fn(|j| {
            if c[j] == 0.0 {
                self.models[j]
            } else {
                let w1 = t[0][j] * mu1 / c[j];
                let w2 = t[1][j] * mu2 / c[j];
                Model::blend(w1, m1, w2, m2)
            }
        });

        // 2. Predict and update each model; 3. its log-likelihood.
        let (u1, g1) = mixed[0].step(dt, q[0], m);
        let (u2, g2) = mixed[1].step(dt, q[1], m);
        let lambda = [-0.5 * g1, -0.5 * g2];

        // 4. Mode probabilities.
        let mut best = f64::NEG_INFINITY;
        for j in 0..2 {
            if c[j] > 0.0 && lambda[j] > best {
                best = lambda[j];
            }
        }
        let e: [f64; 2] = std::array::from_fn(|j| if c[j] > 0.0 { c[j] * (lambda[j] - best).exp() } else { 0.0 });
        let mu = [e[0] / (e[0] + e[1]), e[1] / (e[0] + e[1])];

        (TwoModel { models: [u1, u2], mu }, ModeUpdate { lambda, mu })
    }
}
