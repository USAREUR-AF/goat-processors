// Spec "Frame": the local east/north plane.
const std = @import("std");

pub const R = 6371008.8;

pub fn rad(x: f64) f64 {
    return x * std.math.pi / 180.0;
}

pub fn deg(x: f64) f64 {
    return x * 180.0 / std.math.pi;
}

// Brought into (-180, 180] by adding or subtracting 360.
pub fn wrap180(x: f64) f64 {
    var y = x;
    while (y > 180.0) y -= 360.0;
    while (y <= -180.0) y += 360.0;
    return y;
}

pub const Plane = struct { east: f64, north: f64 };

pub const Frame = struct {
    lat0: f64,
    lon0: f64,

    pub fn toPlane(self: Frame, lat: f64, lon: f64) Plane {
        const dlon = wrap180(lon - self.lon0);
        return .{
            .east = R * rad(dlon) * @cos(rad(self.lat0)),
            .north = R * rad(lat - self.lat0),
        };
    }

    pub fn toDegrees(self: Frame, p: Plane) struct { lat: f64, lon: f64 } {
        const lat = self.lat0 + deg(p.north / R);
        const lon = self.lon0 + deg(p.east / (R * @cos(rad(self.lat0))));
        return .{ .lat = lat, .lon = wrap180(lon) };
    }
};
