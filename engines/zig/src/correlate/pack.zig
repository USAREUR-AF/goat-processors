// Spec "Pack": parsing of pack.def.
const std = @import("std");
const json_read = @import("../io/json_read.zig");
const Allocator = std.mem.Allocator;

const params = @import("../model/params.zig");
const tests = @import("tests.zig");
const methods = @import("methods.zig");

// Spec "Tests": a test of a `gate`, `confirm` or `hold` line, by the test registry.
pub const Test = tests.Test;

// Spec "Track estimate": the `filter` line.
pub const Filter = params.Filter;

// correlate.md "Two-model filter": the `maneuver` line.
pub const Maneuver = params.Maneuver;

// correlate.md 0.7 "Restart": the `restart` line.
pub const Restart = struct {
    gate: f64,
};

// correlate-assign.md 0.5 "Sensor bias": the `bias` line.
pub const Bias = struct {
    sigma_m: f64,
    floor_m: f64,
    gate: f64,
};

// correlate-assign.md 0.6 "Sensor bias", "Time offset": the `time_offset` line.
pub const TimeOffset = struct {
    sigma_ms: f64,
};

// correlate.md 0.8 "Reports", "Time quality".
pub const TimeState = params.TimeState;
pub const TimeDefault = params.TimeDefault;

// correlate.md 1.0 "Association", Stale time of a source: the `stale_rate` line.
pub const StaleRate = struct {
    factor: f64,
    floor_ms: i64,
    ceiling_ms: i64,
    samples: i64,
};

// correlate.md 1.0 "Association", Sequential test: the `sprt` line.
pub const Sprt = struct {
    false: f64,
    missed: f64,
    pos_m: f64,
    vel_ms: f64,
    hae_sigma_m: f64,

    // `up = ln((1 - missed) / false)`, `lo = ln(missed / (1 - false))`.
    pub fn upper(self: Sprt) f64 {
        return @log((1.0 - self.missed) / self.false);
    }
    pub fn lower(self: Sprt) f64 {
        return @log(self.missed / (1.0 - self.false));
    }
};

// correlate.md 1.0: `fused` is the default.
pub const Output = enum { fused, priority, latest };

// Spec "Pack": `method confirm` (correlate.md) or `method assign`
// (correlate-assign.md), from the method registry (methods.zig).
pub const Method = methods.Method;

pub const Priority = struct { source: []const u8, n: f64 };

pub const Pack = struct {
    name: []const u8,
    version: []const u8,
    method: *const Method,
    filter: Filter,
    maneuver: ?Maneuver,
    restart: ?Restart,
    bias: ?Bias,
    // correlate-assign.md 0.6: the clock offset fitted with the position offset.
    time_offset: ?TimeOffset,
    // correlate.md 0.8 "Time quality": per-source defaults, at most one per source.
    time_default: []const TimeDefault,
    gate: []const Test,
    confirm: []const Test,
    hold: []const Test,
    confirm_count: i64,
    hold_failures: i64,
    stale_ms: i64,
    // correlate.md 1.0: staleness from each source's update interval, in place of `stale_ms`.
    stale_rate: ?StaleRate,
    // correlate.md 1.0: confirmation by sequential test, in place of the counts and the hold.
    sprt: ?Sprt,
    same_source_allow: bool,
    output: Output,
    priority: []const Priority,
    // correlate-assign.md "Pack".
    new_cost: f64,
    keep_bonus: f64,
    window: i64,
    hypotheses: i64,
    // correlate-assign.md 0.5 "Window": keep histories within `margin` of the best.
    margin: ?f64,

    // Spec "Fused output": 100 for a source the pack does not list.
    pub fn priorityOf(self: Pack, source: []const u8) f64 {
        for (self.priority) |p| {
            if (std.mem.eql(u8, p.source, source)) return p.n;
        }
        return 100;
    }

    // correlate.md 0.8 "Time quality": the pack's `time_default` for a source.
    pub fn timeDefaultOf(self: Pack, source: []const u8) ?TimeDefault {
        return params.timeDefaultOf(self.time_default, source);
    }
};

pub const Error = error{
    UnknownDirective,
    RepeatedDirective,
    MissingDirective,
    DirectiveNotForMethod,
    WrongArgumentCount,
    UnknownTest,
    UnknownParam,
    RepeatedParam,
    MissingParam,
    ParamWithoutValue,
    NotANumber,
    BadValue,
} || Allocator.Error;

pub const Directive = enum {
    pack,
    version,
    method,
    filter,
    maneuver,
    restart,
    bias,
    time_offset,
    time_default,
    gate,
    confirm,
    hold,
    confirm_count,
    hold_failures,
    stale_ms,
    stale_rate,
    sprt,
    same_source,
    output,
    priority,
    new_cost,
    keep_bonus,
    window,
    hypotheses,
    margin,
};

// The directives a pack.def wrote.
pub const Seen = std.EnumSet(Directive);

// Spec "Pack": `gate`, `confirm`, `hold` and `priority` repeat.
fn repeats(d: Directive) bool {
    return switch (d) {
        .gate, .confirm, .hold, .priority, .time_default => true,
        else => false,
    };
}

// Spec "Pack": numbers are decimal.
fn isDecimal(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false;
    }
    return i == s.len;
}

pub fn parseDecimal(s: []const u8) Error!f64 {
    if (!isDecimal(s)) return error.NotANumber;
    return std.fmt.parseFloat(f64, s) catch error.NotANumber;
}

fn parseCount(s: []const u8) Error!i64 {
    if (s.len == 0) return error.NotANumber;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.NotANumber;
    return std.fmt.parseInt(i64, s, 10) catch error.NotANumber;
}

fn isSemver(s: []const u8) bool {
    const end = std.mem.indexOfAny(u8, s, "-+") orelse s.len;
    var parts = std.mem.splitScalar(u8, s[0..end], '.');
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n == 3 and (end == s.len or end + 1 < s.len);
}

// `name=value` parameters, exactly the fields of T, each once.
fn parseParams(comptime T: type, alloc: Allocator, tokens: []const []const u8) Error!T {
    const fields = @typeInfo(T).Struct.fields;
    var out: T = undefined;
    var seen = [_]bool{false} ** fields.len;
    for (tokens) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.ParamWithoutValue;
        const name = tok[0..eq];
        const value = tok[eq + 1 ..];
        var matched = false;
        inline for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) {
                if (seen[i]) return error.RepeatedParam;
                seen[i] = true;
                matched = true;
                if (f.type == f64) {
                    @field(out, f.name) = try parseDecimal(value);
                } else if (f.type == i64) {
                    @field(out, f.name) = try parseCount(value);
                } else if (f.type == []const u8) {
                    if (value.len == 0) return error.BadValue;
                    @field(out, f.name) = try alloc.dupe(u8, value);
                } else {
                    @compileError("unsupported parameter type");
                }
            }
        }
        if (!matched) return error.UnknownParam;
    }
    for (seen) |s| if (!s) return error.MissingParam;
    return out;
}

// correlate.md 0.8 "Pack": `time_default <source_id>` then `error_ms`, `state`
// or both, at least one, each at most once. `error_ms` is a number 0 or above;
// `state` one of the three clock states. Anything else is a load error.
fn parseTimeDefault(alloc: Allocator, args: []const []const u8) Error!TimeDefault {
    if (args.len < 2) return error.WrongArgumentCount;
    if (std.mem.indexOfScalar(u8, args[0], '=') != null) return error.BadValue;
    var out = TimeDefault{ .source = try alloc.dupe(u8, args[0]), .error_ms = null, .state = null };
    for (args[1..]) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.ParamWithoutValue;
        const name = tok[0..eq];
        const value = tok[eq + 1 ..];
        if (std.mem.eql(u8, name, "error_ms")) {
            if (out.error_ms != null) return error.RepeatedParam;
            const ms = try parseDecimal(value);
            if (!(ms >= 0 and std.math.isFinite(ms))) return error.BadValue;
            out.error_ms = ms;
        } else if (std.mem.eql(u8, name, "state")) {
            if (out.state != null) return error.RepeatedParam;
            out.state = std.meta.stringToEnum(TimeState, value) orelse return error.BadValue;
        } else return error.UnknownParam;
    }
    return out;
}

fn one(args: []const []const u8) Error![]const u8 {
    if (args.len != 1) return error.WrongArgumentCount;
    return args[0];
}

pub fn parse(alloc: Allocator, text: []const u8) Error!Pack {
    return parseWith(alloc, text, tests.default_registry);
}

// Parses a pack.def whose test lines name kinds of `registry`.
pub fn parseWith(alloc: Allocator, text: []const u8, registry: tests.Registry) Error!Pack {
    var seen = Seen.initEmpty();
    var gate = std.ArrayList(Test).init(alloc);
    var confirm = std.ArrayList(Test).init(alloc);
    var hold = std.ArrayList(Test).init(alloc);
    var priority = std.ArrayList(Priority).init(alloc);
    var time_default = std.ArrayList(TimeDefault).init(alloc);
    var pack: Pack = .{
        .name = "",
        .version = "",
        .method = methods.default,
        .filter = undefined,
        .maneuver = null,
        .restart = null,
        .bias = null,
        .time_offset = null,
        .time_default = &.{},
        .gate = &.{},
        .confirm = &.{},
        .hold = &.{},
        .confirm_count = 0,
        .hold_failures = 0,
        .stale_ms = 0,
        .stale_rate = null,
        .sprt = null,
        .same_source_allow = false,
        .output = .fused,
        .priority = &.{},
        .new_cost = 0,
        .keep_bonus = 0,
        .window = 1,
        .hypotheses = 1,
        .margin = null,
    };

    var lines = std.mem.splitScalar(u8, text, '\n');
    var tokens = std.ArrayList([]const u8).init(alloc);
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        tokens.clearRetainingCapacity();
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |t| try tokens.append(t);
        if (tokens.items.len == 0) continue;

        const d = std.meta.stringToEnum(Directive, tokens.items[0]) orelse return error.UnknownDirective;
        if (!repeats(d) and seen.contains(d)) return error.RepeatedDirective;
        seen.insert(d);
        const args = tokens.items[1..];
        switch (d) {
            .pack => pack.name = try alloc.dupe(u8, try one(args)),
            .version => {
                const v = try one(args);
                if (!isSemver(v)) return error.BadValue;
                pack.version = try alloc.dupe(u8, v);
            },
            .method => pack.method = methods.find(try one(args)) orelse return error.BadValue,
            .new_cost => pack.new_cost = try parseDecimal(try one(args)),
            .keep_bonus => pack.keep_bonus = try parseDecimal(try one(args)),
            .filter => pack.filter = try parseParams(Filter, alloc, args),
            .maneuver => pack.maneuver = try parseParams(Maneuver, alloc, args),
            .restart => pack.restart = try parseParams(Restart, alloc, args),
            .bias => pack.bias = try parseParams(Bias, alloc, args),
            .time_offset => pack.time_offset = try parseParams(TimeOffset, alloc, args),
            .time_default => {
                const td = try parseTimeDefault(alloc, args);
                // A second line for the same source is a load error.
                for (time_default.items) |prev| if (std.mem.eql(u8, prev.source, td.source)) return error.RepeatedDirective;
                try time_default.append(td);
            },
            .margin => pack.margin = try parseDecimal(try one(args)),
            .window => pack.window = try parseCount(try one(args)),
            .hypotheses => pack.hypotheses = try parseCount(try one(args)),
            .gate => try gate.append(try registry.parse(alloc, args)),
            .confirm => try confirm.append(try registry.parse(alloc, args)),
            .hold => try hold.append(try registry.parse(alloc, args)),
            .confirm_count => pack.confirm_count = try parseCount(try one(args)),
            .hold_failures => pack.hold_failures = try parseCount(try one(args)),
            .stale_ms => pack.stale_ms = try parseCount(try one(args)),
            .stale_rate => pack.stale_rate = try parseParams(StaleRate, alloc, args),
            .sprt => pack.sprt = try parseParams(Sprt, alloc, args),
            .same_source => {
                const v = try one(args);
                if (std.mem.eql(u8, v, "allow")) {
                    pack.same_source_allow = true;
                } else if (std.mem.eql(u8, v, "forbid")) {
                    pack.same_source_allow = false;
                } else return error.BadValue;
            },
            .output => pack.output = std.meta.stringToEnum(Output, try one(args)) orelse return error.BadValue,
            .priority => {
                if (args.len != 2) return error.WrongArgumentCount;
                try priority.append(.{ .source = try alloc.dupe(u8, args[0]), .n = try parseDecimal(args[1]) });
            },
        }
    }

    // correlate.md 0.4 "Pack": ranges of the `filter` parameters.
    if (seen.contains(.filter)) {
        const f = pack.filter;
        if (!(f.default_ce_m > 0 and f.vel_sigma_ms > 0 and f.unknown_vel_ms > 0 and f.accel_var >= 0)) return error.BadValue;
    }

    // correlate.md 0.6 "Pack": `maneuver` ranges, checked once the whole file is read.
    if (pack.maneuver) |m| {
        if (!(m.p_enter > 0 and m.p_leave > 0 and m.p_enter + m.p_leave < 1)) return error.BadValue;
        if (seen.contains(.filter) and !(m.accel_var > pack.filter.accel_var)) return error.BadValue;
    }

    // correlate.md 0.7 "Pack": `restart`'s `gate` above 0, with either method.
    if (pack.restart) |r| {
        if (!(r.gate > 0)) return error.BadValue;
    }

    // correlate.md 1.0 "Pack": one of `stale_ms` and `stale_rate`, never both,
    // with either method; `stale_rate`'s ranges.
    if (seen.contains(.stale_ms) == seen.contains(.stale_rate)) return error.MissingDirective;
    if (pack.stale_rate) |sr| {
        if (!(sr.factor > 0 and sr.floor_ms >= 0 and sr.floor_ms <= sr.ceiling_ms and sr.samples >= 1)) return error.BadValue;
    }

    // The method's directives (methods.zig): required, refused, then its ranges.
    const m = pack.method;
    for (m.required) |r| if (!seen.contains(r)) return error.MissingDirective;
    for (m.refused) |r| if (seen.contains(r)) return error.DirectiveNotForMethod;
    try m.check(pack, seen);

    pack.gate = try gate.toOwnedSlice();
    pack.confirm = try confirm.toOwnedSlice();
    pack.hold = try hold.toOwnedSlice();
    pack.priority = try priority.toOwnedSlice();
    pack.time_default = try time_default.toOwnedSlice();
    return pack;
}

// Spec operation `load_pack(dir)`.
pub fn load(alloc: Allocator, dir: []const u8) !Pack {
    return loadWith(alloc, dir, tests.default_registry);
}

pub fn loadWith(alloc: Allocator, dir: []const u8, registry: tests.Registry) !Pack {
    return parseWith(alloc, try json_read.readPackDef(alloc, dir), registry);
}

const minimal_confirm =
    \\pack p
    \\version 1.0.0
    \\filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
    \\confirm_count 2
    \\hold_failures 2
    \\stale_ms 1000
;

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "a minimal confirm pack, its defaults, and lines that break it" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const p = try parse(a, minimal_confirm);
        try std.testing.expectEqualStrings("confirm", p.method.name);
        try std.testing.expectEqual(@as(f64, 100), p.priorityOf("x"));
        try std.testing.expect(p.timeDefaultOf("x") == null);
        try std.testing.expectError(error.UnknownDirective, parse(a, minimal_confirm ++ "\nbogus 1"));
        try std.testing.expectError(error.RepeatedDirective, parse(a, minimal_confirm ++ "\nstale_ms 2"));
        try std.testing.expectError(error.DirectiveNotForMethod, parse(a, minimal_confirm ++ "\nnew_cost 2"));
        try std.testing.expectError(error.BadValue, parse(a, minimal_confirm ++ "\nmethod vote"));
        try std.testing.expectError(error.BadValue, parse(a, minimal_confirm ++ "\nmaneuver accel_var=0.5 p_enter=0.1 p_leave=0.2"));
        try std.testing.expectError(error.BadValue, parse(a, minimal_confirm ++ "\nrestart gate=0"));
        try std.testing.expectError(error.RepeatedDirective, parse(a, minimal_confirm ++ "\ntime_default s error_ms=1\ntime_default s state=drifting"));
        try std.testing.expectError(error.NotANumber, parse(a, minimal_confirm ++ "\npriority s x"));
        const q = try parse(a, minimal_confirm ++ "\npriority s 3 # comment\ntime_default s error_ms=1 state=free-running\nsame_source allow\noutput latest");
        try std.testing.expectEqual(@as(f64, 3), q.priorityOf("s"));
        try std.testing.expect(q.same_source_allow);
        try std.testing.expectEqual(TimeState.@"free-running", q.timeDefaultOf("s").?.state.?);
    }

    test "an assign pack and its ranges" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const base =
            \\pack p
            \\version 1.0.0-rc.1
            \\method assign
            \\filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
            \\new_cost 9
            \\keep_bonus 1
            \\stale_ms 1000
        ;
        const p = try parse(a, base);
        try std.testing.expectEqualStrings("s", p.method.group_prefix);
        try std.testing.expectError(error.MissingDirective, parse(a, minimal_confirm ++ "\nmethod assign"));
        try std.testing.expectError(error.DirectiveNotForMethod, parse(a, base ++ "\nconfirm_count 1"));
        try std.testing.expectError(error.BadValue, parse(a, base ++ "\nhypotheses 2"));
        try std.testing.expectError(error.BadValue, parse(a, base ++ "\ntime_offset sigma_ms=5"));
        _ = try parse(a, base ++ "\nwindow 3\nhypotheses 2\nmargin 4\nbias sigma_m=10 floor_m=1 gate=9\ntime_offset sigma_ms=5");
        try std.testing.expectError(error.BadValue, parse(a, base ++ "\nbias sigma_m=1 floor_m=2 gate=9"));
    }

    test "numbers, counts and versions" {
        try std.testing.expect(isDecimal("+1.5e-3"));
        try std.testing.expect(isDecimal(".5"));
        try std.testing.expect(!isDecimal("1e"));
        try std.testing.expect(!isDecimal("."));
        try std.testing.expectError(error.NotANumber, parseCount("-1"));
        try std.testing.expect(isSemver("1.2.3"));
        try std.testing.expect(isSemver("1.2.3+build"));
        try std.testing.expect(!isSemver("1.2"));
        try std.testing.expect(!isSemver("1.2.3-"));
    }
};
