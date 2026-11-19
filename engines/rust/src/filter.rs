//! Frame and track estimate (spec: Frame, Track estimate).

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

/// The local plane, metres east and north of the reference point.
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

    /// Step 2, position update with measurement `z` and variance `r`.
    pub fn update_position(&self, z: f64, r: f64) -> Axis {
        let Axis { p, v, pp, pv, vv } = *self;
        let s = pp + r;
        let k1 = pp / s;
        let k2 = pv / s;
        let y = z - p;
        Axis { p: p + k1 * y, v: v + k2 * y, pp: (1.0 - k1) * pp, pv: (1.0 - k1) * pv, vv: vv - k2 * pv }
    }

    /// Step 3, velocity update with measurement `z` and variance `r`.
    pub fn update_velocity(&self, z: f64, r: f64) -> Axis {
        let Axis { p, v, pp, pv, vv } = *self;
        let s = vv + r;
        let k1 = pv / s;
        let k2 = vv / s;
        let y = z - v;
        Axis { p: p + k1 * y, v: v + k2 * y, pp: pp - k1 * pv, pv: (1.0 - k2) * pv, vv: (1.0 - k2) * vv }
    }

    pub fn as_list(&self) -> [f64; 5] {
        [self.p, self.v, self.pp, self.pv, self.vv]
    }
}
