// Spec "Tests": A is the entity just reported, B is predicted to A's `time_ms`.
const std = @import("std");
const json = std.json;
const pack_mod = @import("pack.zig");
const kalman = @import("kalman.zig");
const Entity = @import("entity.zig").Entity;

pub const Outcome = struct {
    value: json.Value,
    limit: json.Value,
    pass: bool,
    skipped: bool = false,
};

const skipped: Outcome = .{ .value = .null, .limit = .null, .pass = true, .skipped = true };

fn num(x: f64) json.Value {
    return .{ .float = x };
}

fn distance(a: Entity, b_pred: kalman.Filter) f64 {
    const de = a.filter.east.p - b_pred.east.p;
    const dn = a.filter.north.p - b_pred.north.p;
    return @sqrt(de * de + dn * dn);
}

// `d²` of spec "Tests", also the `rank` of spec "Association".
pub fn mahalanobis(a: Entity, b_pred: kalman.Filter, default_ce_m: f64) f64 {
    const ce_a = a.ce(default_ce_m);
    const r = ce_a * ce_a;
    const de = a.filter.east.p - b_pred.east.p;
    const dn = a.filter.north.p - b_pred.north.p;
    return de * de / (b_pred.east.pp + r) + dn * dn / (b_pred.north.pp + r);
}

// Spec 0.2: every value comes from the last accepted report; skipped when absent or below `min_speed_ms`.
fn speedsUsable(a: Entity, b: Entity, min_speed_ms: f64) ?[2]f64 {
    const sa = a.number("speed_ms") orelse return null;
    const sb = b.number("speed_ms") orelse return null;
    if (sa < min_speed_ms or sb < min_speed_ms) return null;
    return .{ sa, sb };
}

// Spec 0.3 "Tests": strings byte for byte, numbers by value, never a string against a number.
fn valuesEqual(x: json.Value, y: json.Value) bool {
    switch (x) {
        .string => |s| return y == .string and std.mem.eql(u8, s, y.string),
        .bool => |v| return y == .bool and v == y.bool,
        .integer, .float, .number_string => {
            const fx = asNumber(x) orelse return false;
            const fy = asNumber(y) orelse return false;
            return fx == fy;
        },
        .null => return y == .null,
        .array => |xs| {
            if (y != .array or xs.items.len != y.array.items.len) return false;
            for (xs.items, y.array.items) |xi, yi| if (!valuesEqual(xi, yi)) return false;
            return true;
        },
        .object => |xo| {
            if (y != .object or xo.count() != y.object.count()) return false;
            var it = xo.iterator();
            while (it.next()) |e| {
                const yv = y.object.get(e.key_ptr.*) orelse return false;
                if (!valuesEqual(e.value_ptr.*, yv)) return false;
            }
            return true;
        },
    }
}

fn asNumber(v: json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn run(t: pack_mod.Test, a: Entity, b: Entity, b_pred: kalman.Filter, filter: pack_mod.Filter) Outcome {
    switch (t) {
        .distance => |p| {
            const d = distance(a, b_pred);
            return .{ .value = num(d), .limit = num(p.max_m), .pass = d < p.max_m };
        },
        .window => |p| {
            const ea = std.math.clamp(a.ce(filter.default_ce_m), p.err_min_m, p.err_max_m);
            const eb = std.math.clamp(b.ce(filter.default_ce_m), p.err_min_m, p.err_max_m);
            const limit = p.multiplier * @sqrt(ea * ea + eb * eb) + p.window_m;
            const d = distance(a, b_pred);
            return .{ .value = num(d), .limit = num(limit), .pass = d < limit };
        },
        .mahalanobis => |p| {
            const d2 = mahalanobis(a, b_pred, filter.default_ce_m);
            return .{ .value = num(d2), .limit = num(p.gate), .pass = d2 < p.gate };
        },
        .course => |p| {
            const ca = a.number("course") orelse return skipped;
            const cb = b.number("course") orelse return skipped;
            _ = speedsUsable(a, b, p.min_speed_ms) orelse return skipped;
            const diff = @abs(ca - cb);
            const value = @min(diff, 360.0 - diff);
            return .{ .value = num(value), .limit = num(p.max_deg), .pass = value <= p.max_deg };
        },
        .speed => |p| {
            const s = speedsUsable(a, b, p.min_speed_ms) orelse return skipped;
            const slow = @min(s[0], s[1]);
            const fast = @max(s[0], s[1]);
            const value = if (fast == 0.0) 0.0 else @abs(1.0 - slow / fast) * 100.0;
            return .{ .value = num(value), .limit = num(p.max_pct), .pass = value <= p.max_pct };
        },
        .altitude => |p| {
            const ha = a.number("hae") orelse return skipped;
            const hb = b.number("hae") orelse return skipped;
            const value = @abs(ha - hb);
            return .{ .value = num(value), .limit = num(p.max_m), .pass = value <= p.max_m };
        },
        .same => |p| {
            const va = a.sameValue(p.key);
            const vb = b.sameValue(p.key);
            const pass = if (va != null and vb != null) valuesEqual(va.?, vb.?) else (va == null and vb == null);
            return .{ .value = va orelse .null, .limit = vb orelse .null, .pass = pass };
        },
    }
}
