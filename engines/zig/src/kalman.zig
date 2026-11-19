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

// One report's measurements in the plane, with their variances.
pub const Measurement = struct {
    east: f64,
    north: f64,
    r_pos: f64, // ce²
    vel: ?struct { east: f64, north: f64 } = null,
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

    pub fn predict(f: Filter, dt: f64, q: f64) Filter {
        return .{ .east = f.east.predict(dt, q), .north = f.north.predict(dt, q) };
    }

    // Steps 2 and 3 on a predicted filter. `g` is the sum of the update terms,
    // east position, north position, then east and north velocity, added left
    // to right from 0 (used only by the two-model filter).
    pub fn update(f: Filter, m: Measurement) struct { filter: Filter, g: f64 } {
        var out = f;
        var g: f64 = 0;
        g += term(m.east - out.east.p, out.east.pp + m.r_pos);
        g += term(m.north - out.north.p, out.north.pp + m.r_pos);
        out.east = out.east.updatePosition(m.east, m.r_pos);
        out.north = out.north.updatePosition(m.north, m.r_pos);
        if (m.vel) |v| {
            g += term(v.east - out.east.v, out.east.vv + m.r_vel);
            g += term(v.north - out.north.v, out.north.vv + m.r_vel);
            out.east = out.east.updateVelocity(v.east, m.r_vel);
            out.north = out.north.updateVelocity(v.north, m.r_vel);
        }
        return .{ .filter = out, .g = g };
    }
};
