// Spec "Track estimate": a constant-velocity Kalman filter per axis.
const std = @import("std");

pub const Axis = struct {
    p: f64,
    v: f64,
    pp: f64,
    pv: f64,
    vv: f64,

    // First report.
    pub fn init(z: f64, vel: ?f64, ce: f64, vel_sigma_ms: f64, unknown_vel_ms: f64) Axis {
        return .{
            .p = z,
            .v = vel orelse 0.0,
            .pp = ce * ce,
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

pub const Filter = struct {
    east: Axis,
    north: Axis,

    pub fn predict(f: Filter, dt: f64, q: f64) Filter {
        return .{ .east = f.east.predict(dt, q), .north = f.north.predict(dt, q) };
    }
};
