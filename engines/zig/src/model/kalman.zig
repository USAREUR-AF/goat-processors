// Spec "Track estimate": a constant-velocity Kalman filter per axis. Every
// function here is pure: it returns a new state and changes nothing.
const std = @import("std");
const frame = @import("frame.zig");

pub const Velocity = struct { east: f64, north: f64 };

// Spec "Track estimate", the velocity measurement: from `course` (degrees from
// north) and `speed_ms`, both present; null otherwise.
pub fn velocityOf(course: ?f64, speed_ms: ?f64) ?Velocity {
    const c = course orelse return null;
    const sp = speed_ms orelse return null;
    return .{ .east = sp * @sin(frame.rad(c)), .north = sp * @cos(frame.rad(c)) };
}

pub const Axis = struct {
    p: f64,
    v: f64,
    pp: f64,
    pv: f64,
    vv: f64,

    // First report, with `pp = ce²` (the measurement variance when the time is exact).
    pub fn init(z: f64, vel: ?f64, ce: f64, vel_sigma_ms: f64, unknown_vel_ms: f64) Axis {
        return initWithVariance(z, vel, ce * ce, vel_sigma_ms, unknown_vel_ms);
    }

    // First report, correlate.md 0.8: `pp = r`, that axis's measurement variance.
    pub fn initWithVariance(z: f64, vel: ?f64, r: f64, vel_sigma_ms: f64, unknown_vel_ms: f64) Axis {
        return .{
            .p = z,
            .v = vel orelse 0.0,
            .pp = r,
            .pv = 0.0,
            .vv = if (vel != null) vel_sigma_ms * vel_sigma_ms else unknown_vel_ms * unknown_vel_ms,
        };
    }

    // Step 1, predict. Also the prediction of an entity to a time.
    pub fn predict(a: Axis, dt: f64, q: f64) Axis {
        return .{
            .p = a.p + a.v * dt,
            .v = a.v,
            .pp = a.pp + 2.0 * dt * a.pv + dt * dt * a.vv + q * (dt * dt * dt * dt) / 4.0,
            .pv = a.pv + dt * a.vv + q * (dt * dt * dt) / 2.0,
            .vv = a.vv + q * (dt * dt),
        };
    }

    // Step 2, position update.
    pub fn updatePosition(a: Axis, z: f64, r: f64) Axis {
        const s = a.pp + r;
        const k1 = a.pp / s;
        const k2 = a.pv / s;
        const y = z - a.p;
        return .{
            .p = a.p + k1 * y,
            .v = a.v + k2 * y,
            .pp = (1.0 - k1) * a.pp,
            .pv = (1.0 - k1) * a.pv,
            .vv = a.vv - k2 * a.pv,
        };
    }

    // Step 3, velocity update.
    pub fn updateVelocity(a: Axis, z: f64, r: f64) Axis {
        const s = a.vv + r;
        const k1 = a.pv / s;
        const k2 = a.vv / s;
        const y = z - a.v;
        return .{
            .p = a.p + k1 * y,
            .v = a.v + k2 * y,
            .pp = a.pp - k1 * a.pv,
            .pv = (1.0 - k2) * a.pv,
            .vv = (1.0 - k2) * a.vv,
        };
    }
};

// One report's measurements in the plane, with their variances.
pub const Measurement = struct {
    east: f64,
    north: f64,
    // correlate.md 0.8 "Measurement variance": the position variance per axis,
    // ce² plus the timing term (v*ts)² of that axis.
    r_east: f64,
    r_north: f64,
    vel: ?Velocity = null,
    r_vel: f64, // vel_sigma_ms²
};

// Spec "Two-model filter", step 3: the term `y*y/s + ln(s)` of one scalar update,
// from the state before that update.
fn term(y: f64, s: f64) f64 {
    return y * y / s + @log(s);
}

pub const Filter = struct {
    east: Axis,
    north: Axis,

    // A first report: per axis the position, the velocity when measured, and
    // `pp` the measurement variance of that axis.
    pub fn first(m: Measurement, vel_sigma_ms: f64, unknown_vel_ms: f64) Filter {
        const ve: ?f64 = if (m.vel) |v| v.east else null;
        const vn: ?f64 = if (m.vel) |v| v.north else null;
        return .{
            .east = Axis.initWithVariance(m.east, ve, m.r_east, vel_sigma_ms, unknown_vel_ms),
            .north = Axis.initWithVariance(m.north, vn, m.r_north, vel_sigma_ms, unknown_vel_ms),
        };
    }

    pub fn predict(f: Filter, dt: f64, q: f64) Filter {
        return .{ .east = f.east.predict(dt, q), .north = f.north.predict(dt, q) };
    }

    // Steps 2 and 3 on a predicted filter. `g` is the sum of the update terms,
    // east position, north position, then east and north velocity, added left
    // to right from 0 (used only by the two-model filter).
    pub fn update(f: Filter, m: Measurement) struct { filter: Filter, g: f64 } {
        var out = f;
        var g: f64 = 0;
        g += term(m.east - out.east.p, out.east.pp + m.r_east);
        g += term(m.north - out.north.p, out.north.pp + m.r_north);
        out.east = out.east.updatePosition(m.east, m.r_east);
        out.north = out.north.updatePosition(m.north, m.r_north);
        if (m.vel) |v| {
            g += term(v.east - out.east.v, out.east.vv + m.r_vel);
            g += term(v.north - out.north.v, out.north.vv + m.r_vel);
            out.east = out.east.updateVelocity(v.east, m.r_vel);
            out.north = out.north.updateVelocity(v.north, m.r_vel);
        }
        return .{ .filter = out, .g = g };
    }
};

// dt in seconds from `from_ms` to `to_ms`.
pub fn seconds(from_ms: i64, to_ms: i64) f64 {
    return @as(f64, @floatFromInt(to_ms - from_ms)) / 1000.0;
}

test "predict then update moves toward the measurement and shrinks the variance" {
    const a = Axis.init(0, null, 10, 1, 100);
    try std.testing.expectEqual(@as(f64, 100), a.pp);
    try std.testing.expectEqual(@as(f64, 10000), a.vv);
    const p = a.predict(1, 0);
    try std.testing.expectEqual(@as(f64, 10100), p.pp);
    const u = p.updatePosition(50, 100);
    try std.testing.expect(u.p > 0 and u.p < 50);
    try std.testing.expect(u.pp < p.pp);
    const f = Filter{ .east = a, .north = a };
    const m = Measurement{ .east = 1, .north = 2, .r_east = 100, .r_north = 100, .vel = .{ .east = 1, .north = 0 }, .r_vel = 1 };
    const r = f.predict(1, 0.1).update(m);
    try std.testing.expect(r.g > 0);
    try std.testing.expect(r.filter.east.v > 0);
}

test "velocity measurement needs course and speed" {
    try std.testing.expect(velocityOf(null, 3) == null);
    try std.testing.expect(velocityOf(90, null) == null);
    const v = velocityOf(90, 2).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2), v.east, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), v.north, 1e-12);
}
