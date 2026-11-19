// spec/fuse.md "Kinematics": combining the members' predicted filters.
// Pure arithmetic; the engine (fuse.zig) chooses the method and writes the trace.
const std = @import("std");
const kalman = @import("kalman.zig");

// Per axis: `p`, `v`, `pp`, `vv`.
pub const AxisEstimate = struct {
    p: f64,
    v: f64,
    pp: f64,
    vv: f64,

    pub fn of(a: kalman.Axis) AxisEstimate {
        return .{ .p = a.p, .v = a.v, .pp = a.pp, .vv = a.vv };
    }
};

pub const Estimate = struct {
    east: AxisEstimate,
    north: AxisEstimate,

    // A member's predicted filter as an estimate.
    pub fn of(f: kalman.Filter) Estimate {
        return .{ .east = AxisEstimate.of(f.east), .north = AxisEstimate.of(f.north) };
    }
};

// **Position variance** of a member: `var = ppe + ppn`.
pub fn positionVariance(f: kalman.Filter) f64 {
    return f.east.pp + f.north.pp;
}

// `inverse_variance`, one axis, members in key order.
fn inverseVarianceAxis(axes: []const AxisEstimate) AxisEstimate {
    var ip: f64 = 0;
    var sp: f64 = 0;
    var iv: f64 = 0;
    var sv: f64 = 0;
    for (axes) |a| {
        ip = ip + 1.0 / a.pp;
        sp = sp + a.p / a.pp;
        iv = iv + 1.0 / a.vv;
        sv = sv + a.v / a.vv;
    }
    const pp = 1.0 / ip;
    const vv = 1.0 / iv;
    return .{ .p = pp * sp, .v = vv * sv, .pp = pp, .vv = vv };
}

// `inverse_variance`: east first, then north. With one member the result is
// that member's predicted filter.
pub fn inverseVariance(members: []const Estimate, scratch: []AxisEstimate) Estimate {
    if (members.len == 1) return members[0];
    for (members, 0..) |m, i| scratch[i] = m.east;
    const east = inverseVarianceAxis(scratch[0..members.len]);
    for (members, 0..) |m, i| scratch[i] = m.north;
    const north = inverseVarianceAxis(scratch[0..members.len]);
    return .{ .east = east, .north = north };
}

// `covariance_intersection`, Weight: the closed form, steps 1 to 5 in order.
pub fn intersectionWeight(x: Estimate, y: Estimate) f64 {
    const ae = 1.0 / y.east.pp;
    const an = 1.0 / y.north.pp;
    const de = 1.0 / x.east.pp - ae;
    const dn = 1.0 / x.north.pp - an;
    const c2 = de * dn;
    const c1 = ae * dn + an * de;
    if (c2 < 0) {
        var w = -c1 / (2.0 * c2);
        if (w < 0) w = 0;
        if (w > 1) w = 1;
        return w;
    }
    if (c1 + c2 > 0) return 1;
    if (c1 + c2 < 0) return 0;
    return 0.5;
}

// `covariance_intersection`, Fold, one axis.
fn foldAxis(x: AxisEstimate, y: AxisEstimate, w: f64) AxisEstimate {
    const a = w / x.pp;
    const b = (1.0 - w) / y.pp;
    const pp = 1.0 / (a + b);
    const p = pp * (a * x.p + b * y.p);
    const c = w / x.vv;
    const d = (1.0 - w) / y.vv;
    const vv = 1.0 / (c + d);
    const v = vv * (c * x.v + d * y.v);
    return .{ .p = p, .v = v, .pp = pp, .vv = vv };
}

// `covariance_intersection`, Fold: `w = 1` keeps X, `w = 0` takes Y.
pub fn fold(x: Estimate, y: Estimate, w: f64) Estimate {
    if (w == 1) return x;
    if (w == 0) return y;
    return .{ .east = foldAxis(x.east, y.east, w), .north = foldAxis(x.north, y.north, w) };
}

test "weight is 0.5 for equal variances and picks the smaller variance otherwise" {
    const small = Estimate{ .east = .{ .p = 0, .v = 0, .pp = 900, .vv = 1 }, .north = .{ .p = 0, .v = 0, .pp = 900, .vv = 1 } };
    const large = Estimate{ .east = .{ .p = 0, .v = 0, .pp = 1600, .vv = 1 }, .north = .{ .p = 0, .v = 0, .pp = 1600, .vv = 1 } };
    try std.testing.expectEqual(@as(f64, 0.5), intersectionWeight(small, small));
    try std.testing.expectEqual(@as(f64, 1), intersectionWeight(small, large));
    try std.testing.expectEqual(@as(f64, 0), intersectionWeight(large, small));
}
