// Spec "Tests": A is the entity just reported, B is predicted to A's `time_ms`.
//
// The registration point of a test kind: `builtin` below. A kind is a name,
// its parameters (each a number or a text, by name) and a pure `run` from the
// pair and the parameters to the record's value, limit and pass. A pack's
// `gate`, `confirm` and `hold` lines are parsed against a Registry (the
// builtin kinds unless the caller gives another, as the tests' no-op kind does).
const std = @import("std");
const json = std.json;
const pack_mod = @import("pack.zig");
const kalman = @import("../model/kalman.zig");
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

// `d²` of spec "Tests", also the `rank` of spec "Association". `b_pred` is B's
// prediction with its timing variance already added (`predictedForComparison`);
// `r_a` is A's measurement variance on that axis (ce_a² when its time error is 0).
pub fn mahalanobis(a: Entity, b_pred: kalman.Filter) f64 {
    const de = a.filter.east.p - b_pred.east.p;
    const dn = a.filter.north.p - b_pred.north.p;
    return de * de / (b_pred.east.pp + a.r_east) + dn * dn / (b_pred.north.pp + a.r_north);
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

// ---- the registry -------------------------------------------------------------

pub const ParamKind = enum { number, text };
pub const Param = struct { name: []const u8, kind: ParamKind };
pub const Arg = union(ParamKind) { number: f64, text: []const u8 };

// What a test reads: A, B, B's prediction (to A's time, with B's timing
// variance and, with `bias`, moved into A's frame) and the pack's `filter`.
pub const Pair = struct { a: Entity, b: Entity, b_pred: kalman.Filter, filter: pack_mod.Filter };

pub const Kind = struct {
    name: []const u8,
    params: []const Param,
    run: *const fn (pair: Pair, args: []const Arg) Outcome,
};

// One test of a pack line: its kind and its arguments, in the kind's parameter order.
pub const Test = struct {
    kind: *const Kind,
    args: []const Arg,

    pub fn name(t: Test) []const u8 {
        return t.kind.name;
    }

    pub fn run(t: Test, pair: Pair) Outcome {
        return t.kind.run(pair, t.args);
    }
};

pub const Registry = struct {
    kinds: []const Kind,

    pub fn find(r: Registry, name_: []const u8) ?*const Kind {
        for (r.kinds) |*k| if (std.mem.eql(u8, k.name, name_)) return k;
        return null;
    }

    // A test line after its directive: the kind's name, then `name=value`
    // parameters, exactly the kind's, each once.
    pub fn parse(r: Registry, alloc: std.mem.Allocator, tokens: []const []const u8) pack_mod.Error!Test {
        if (tokens.len == 0) return error.WrongArgumentCount;
        const kind = r.find(tokens[0]) orelse return error.UnknownTest;
        const args = try alloc.alloc(Arg, kind.params.len);
        const seen = try alloc.alloc(bool, kind.params.len);
        @memset(seen, false);
        for (tokens[1..]) |tok| {
            const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.ParamWithoutValue;
            const pname = tok[0..eq];
            const value = tok[eq + 1 ..];
            const i = for (kind.params, 0..) |p, j| {
                if (std.mem.eql(u8, p.name, pname)) break j;
            } else return error.UnknownParam;
            if (seen[i]) return error.RepeatedParam;
            seen[i] = true;
            args[i] = switch (kind.params[i].kind) {
                .number => .{ .number = try pack_mod.parseDecimal(value) },
                .text => blk: {
                    if (value.len == 0) return error.BadValue;
                    break :blk .{ .text = try alloc.dupe(u8, value) };
                },
            };
        }
        for (seen) |x| if (!x) return error.MissingParam;
        return .{ .kind = kind, .args = args };
    }
};

// The builtin kinds, spec "Tests". Adding a test is one entry here.
pub const builtin = [_]Kind{
    .{ .name = "distance", .params = &.{.{ .name = "max_m", .kind = .number }}, .run = runDistance },
    .{ .name = "window", .params = &.{ .{ .name = "multiplier", .kind = .number }, .{ .name = "window_m", .kind = .number }, .{ .name = "err_min_m", .kind = .number }, .{ .name = "err_max_m", .kind = .number } }, .run = runWindow },
    .{ .name = "mahalanobis", .params = &.{.{ .name = "gate", .kind = .number }}, .run = runMahalanobis },
    .{ .name = "course", .params = &.{ .{ .name = "max_deg", .kind = .number }, .{ .name = "min_speed_ms", .kind = .number } }, .run = runCourse },
    .{ .name = "speed", .params = &.{ .{ .name = "max_pct", .kind = .number }, .{ .name = "min_speed_ms", .kind = .number } }, .run = runSpeed },
    .{ .name = "altitude", .params = &.{.{ .name = "max_m", .kind = .number }}, .run = runAltitude },
    .{ .name = "same", .params = &.{.{ .name = "key", .kind = .text }}, .run = runSame },
};

pub const default_registry = Registry{ .kinds = &builtin };

// ---- the builtin kinds ------------------------------------------------------------

fn runDistance(pr: Pair, args: []const Arg) Outcome {
    const max_m = args[0].number;
    const d = distance(pr.a, pr.b_pred);
    return .{ .value = num(d), .limit = num(max_m), .pass = d < max_m };
}

// The `window` test, unchanged (correlate 1.0 replaces it).
fn runWindow(pr: Pair, args: []const Arg) Outcome {
    const p = .{ .multiplier = args[0].number, .window_m = args[1].number, .err_min_m = args[2].number, .err_max_m = args[3].number };
    const a = pr.a;
    const b = pr.b;
    const ea = std.math.clamp(a.ce(pr.filter.default_ce_m), p.err_min_m, p.err_max_m);
    const eb = std.math.clamp(b.ce(pr.filter.default_ce_m), p.err_min_m, p.err_max_m);
    const limit = p.multiplier * @sqrt(ea * ea + eb * eb) + p.window_m;
    const d = distance(a, pr.b_pred);
    return .{ .value = num(d), .limit = num(limit), .pass = d < limit };
}

fn runMahalanobis(pr: Pair, args: []const Arg) Outcome {
    const gate = args[0].number;
    const d2 = mahalanobis(pr.a, pr.b_pred);
    return .{ .value = num(d2), .limit = num(gate), .pass = d2 < gate };
}

fn runCourse(pr: Pair, args: []const Arg) Outcome {
    const max_deg = args[0].number;
    const min_speed_ms = args[1].number;
    const ca = pr.a.number("course") orelse return skipped;
    const cb = pr.b.number("course") orelse return skipped;
    _ = speedsUsable(pr.a, pr.b, min_speed_ms) orelse return skipped;
    const diff = @abs(ca - cb);
    const value = @min(diff, 360.0 - diff);
    return .{ .value = num(value), .limit = num(max_deg), .pass = value <= max_deg };
}

fn runSpeed(pr: Pair, args: []const Arg) Outcome {
    const max_pct = args[0].number;
    const min_speed_ms = args[1].number;
    const s = speedsUsable(pr.a, pr.b, min_speed_ms) orelse return skipped;
    const slow = @min(s[0], s[1]);
    const fast = @max(s[0], s[1]);
    const value = if (fast == 0.0) 0.0 else @abs(1.0 - slow / fast) * 100.0;
    return .{ .value = num(value), .limit = num(max_pct), .pass = value <= max_pct };
}

fn runAltitude(pr: Pair, args: []const Arg) Outcome {
    const max_m = args[0].number;
    const ha = pr.a.number("hae") orelse return skipped;
    const hb = pr.b.number("hae") orelse return skipped;
    const value = @abs(ha - hb);
    return .{ .value = num(value), .limit = num(max_m), .pass = value <= max_m };
}

// The `same` test, unchanged (correlate 1.0 replaces it).
fn runSame(pr: Pair, args: []const Arg) Outcome {
    const key = args[0].text;
    const va = pr.a.sameValue(key);
    const vb = pr.b.sameValue(key);
    const pass = if (va != null and vb != null) valuesEqual(va.?, vb.?) else (va == null and vb == null);
    return .{ .value = va orelse .null, .limit = vb orelse .null, .pass = pass };
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "the registry parses parameters by name, once each, and refuses unknown kinds" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const r = default_registry;
        const t = try r.parse(a, &.{ "course", "min_speed_ms=2", "max_deg=30" });
        try std.testing.expectEqualStrings("course", t.name());
        try std.testing.expectEqual(@as(f64, 30), t.args[0].number);
        try std.testing.expectEqual(@as(f64, 2), t.args[1].number);
        try std.testing.expectError(error.UnknownTest, r.parse(a, &.{"noop"}));
        try std.testing.expectError(error.RepeatedParam, r.parse(a, &.{ "distance", "max_m=1", "max_m=2" }));
        try std.testing.expectError(error.MissingParam, r.parse(a, &.{"distance"}));
        try std.testing.expectError(error.UnknownParam, r.parse(a, &.{ "distance", "max=1" }));
        try std.testing.expectError(error.ParamWithoutValue, r.parse(a, &.{ "distance", "max_m" }));
        try std.testing.expectError(error.BadValue, r.parse(a, &.{ "same", "key=" }));
        try std.testing.expectError(error.WrongArgumentCount, r.parse(a, &.{}));
        const s = try r.parse(a, &.{ "same", "key=@env" });
        try std.testing.expectEqualStrings("@env", s.args[0].text);
    }
};
