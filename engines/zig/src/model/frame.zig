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

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "wrap180 brings into (-180, 180]" {
        try std.testing.expectEqual(@as(f64, 180), wrap180(-180));
        try std.testing.expectEqual(@as(f64, -170), wrap180(190));
        try std.testing.expectEqual(@as(f64, 10), wrap180(370));
    }

    test "plane and back is the identity, across the antimeridian" {
        const f = Frame{ .lat0 = 10, .lon0 = 179.9 };
        const p = f.toPlane(10.01, -179.95);
        try std.testing.expect(p.east > 0 and p.north > 0);
        const back = f.toDegrees(p);
        try std.testing.expectApproxEqAbs(@as(f64, 10.01), back.lat, 1e-9);
        try std.testing.expectApproxEqAbs(@as(f64, -179.95), back.lon, 1e-9);
        try std.testing.expectEqual(@as(f64, 0), f.toPlane(10, 179.9).east);
    }
};
