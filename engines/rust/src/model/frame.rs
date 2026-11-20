//! correlate.md Frame: the local plane, meters east and north of the
//! reference point, and the angle helpers. Pure functions only.

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
