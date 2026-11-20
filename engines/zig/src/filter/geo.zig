// spec/filter.md "Geometry": distance, polygon test, reference prediction.
// R, rad, deg and wrap are the correlate engine's (src/frame.zig); the
// definitions are the same in both specifications.
const std = @import("std");
const frame = @import("../model/frame.zig");
const fpack = @import("pack.zig");

const R = frame.R;
const rad = frame.rad;
const deg = frame.deg;
const wrap = frame.wrap180;

// Distance (haversine), point 1 is the report being decided.
pub fn distance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    // 1.
    const p1 = rad(lat1);
    const p2 = rad(lat2);
    const dp = rad(lat2 - lat1);
    const dl = rad(wrap(lon2 - lon1));
    // 2.
    const s1 = @sin(dp / 2.0);
    const s2 = @sin(dl / 2.0);
    // 3.
    const h = s1 * s1 + ((@cos(p1) * @cos(p2)) * s2) * s2;
    // 4.
    return (2.0 * R) * std.math.asin(@min(1.0, @sqrt(h)));
}

pub const Side = enum {
    boundary,
    inside,
    outside,

    pub fn name(self: Side) []const u8 {
        return @tagName(self);
    }
};

// Polygon: flat plane, x = longitude unwrapped to within 180 of vertex 0.
pub fn polygon(vertices: []const fpack.Vertex, lat: f64, lon: f64) Side {
    const lon0 = vertices[0].lon;
    const n = vertices.len;
    const px = lon0 + wrap(lon - lon0);
    const py = lat;
    const x = struct {
        fn at(vs: []const fpack.Vertex, l0: f64, i: usize) f64 {
            return if (i == 0) l0 else l0 + wrap(vs[i].lon - l0);
        }
    }.at;

    // 1. Boundary.
    for (0..n) |i| {
        const j = (i + 1) % n;
        const xi = x(vertices, lon0, i);
        const xj = x(vertices, lon0, j);
        const yi = vertices[i].lat;
        const yj = vertices[j].lat;
        const c = (xj - xi) * (py - yi) - (yj - yi) * (px - xi);
        if (c == 0 and @min(xi, xj) <= px and px <= @max(xi, xj) and @min(yi, yj) <= py and py <= @max(yi, yj)) {
            return .boundary;
        }
    }

    // 2. Crossings (even-odd rule).
    var inside = false;
    for (0..n) |i| {
        const j = (i + 1) % n;
        const xi = x(vertices, lon0, i);
        const xj = x(vertices, lon0, j);
        const yi = vertices[i].lat;
        const yj = vertices[j].lat;
        if ((yi > py) != (yj > py)) {
            const xc = (xj - xi) * (py - yi) / (yj - yi) + xi;
            if (px < xc) inside = !inside;
        }
    }
    return if (inside) .inside else .outside;
}

pub const Position = struct { lat: f64, lon: f64 };

// Reference prediction to time `t_ms`.
pub fn predict(time_ms: i64, lat: f64, lon: f64, course: ?f64, speed_ms: ?f64, t_ms: i64) Position {
    // 1.
    const dt = @as(f64, @floatFromInt(@as(i128, t_ms) - time_ms)) / 1000.0;
    // 2.
    var dn: f64 = 0;
    var de: f64 = 0;
    if (course != null and speed_ms != null) {
        dn = speed_ms.? * @cos(rad(course.?)) * dt;
        de = speed_ms.? * @sin(rad(course.?)) * dt;
    }
    // 3.
    return .{
        .lat = lat + deg(dn / R),
        .lon = wrap(lon + deg(de / (R * @cos(rad(lat))))),
    };
}

test "polygon boundary, inside, outside, across the antimeridian" {
    const box = [_]fpack.Vertex{ .{ .lat = -10, .lon = 175 }, .{ .lat = -10, .lon = -175 }, .{ .lat = 10, .lon = -175 }, .{ .lat = 10, .lon = 175 } };
    try std.testing.expectEqual(Side.inside, polygon(&box, 0, 180));
    try std.testing.expectEqual(Side.inside, polygon(&box, 0, -179));
    try std.testing.expectEqual(Side.boundary, polygon(&box, 10, 179));
    try std.testing.expectEqual(Side.outside, polygon(&box, 0, 170));
}
