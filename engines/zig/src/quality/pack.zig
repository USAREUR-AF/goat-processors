// spec/quality.md 0.2 "Pack" and "Rules": parsing of a quality pack.def.
const std = @import("std");
const json_read = @import("../io/json_read.zig");
const Allocator = std.mem.Allocator;
const params = @import("../model/params.zig");
const measures = @import("measures.zig");

// spec/quality.md "Frame and filter": the `filter` line has the parameters of
// correlate.md "Track estimate", so the correlate type is reused.
pub const Filter = params.Filter;

// spec/quality.md "Reports", "Time quality": the clock states and the
// `time_default` line are those of correlate.md 0.8, so the correlate types
// are reused.
pub const TimeState = params.TimeState;
pub const TimeDefault = params.TimeDefault;

// "Time quality": the code of a time state for measures; higher is worse.
pub fn timeStateCode(state: TimeState) i64 {
    return switch (state) {
        .coherent => 0,
        .drifting => 1,
        .@"free-running" => 2,
    };
}

// The `window` line.
pub const Window = struct {
    window_ms: i64,
    min_samples: i64,
    forget_ms: i64,
};

pub const Scope = enum { entity, source };

// "Entity measures" and "Source measures": the measure registry (measures.zig).
pub const Measure = measures.Measure;

// A rule's measure must be one of its scope's: `entities` is a source measure only.
pub fn inScope(m: Measure, scope: Scope) bool {
    return !measures.entry(m).source_only or scope == .source;
}

pub const Op = enum {
    lt,
    le,
    gt,
    ge,

    pub fn parse(s: []const u8) ?Op {
        if (std.mem.eql(u8, s, "<")) return .lt;
        if (std.mem.eql(u8, s, "<=")) return .le;
        if (std.mem.eql(u8, s, ">")) return .gt;
        if (std.mem.eql(u8, s, ">=")) return .ge;
        return null;
    }

    // "Rules", evaluation: `v op limit`.
    pub fn holds(op: Op, v: f64, limit: f64) bool {
        return switch (op) {
            .lt => v < limit,
            .le => v <= limit,
            .gt => v > limit,
            .ge => v >= limit,
        };
    }

    // "Rules", evaluation: for `>`/`>=` an active rule clears when `v < clear`;
    // for `<`/`<=` when `v > clear`.
    pub fn clears(op: Op, v: f64, clear: f64) bool {
        return switch (op) {
            .gt, .ge => v < clear,
            .lt, .le => v > clear,
        };
    }
};

pub const Action = enum { mark, downgrade, drop, alert };

pub const Rule = struct {
    name: []const u8,
    scope: Scope,
    measure: Measure,
    op: Op,
    limit: f64,
    for_n: i64,
    clear: f64,
    action: Action,
    factor: ?f64,
};

pub const Pack = struct {
    name: []const u8,
    version: []const u8,
    filter: Filter,
    window: Window,
    // "Time quality": per-source defaults, at most one per source id.
    time_default: []const TimeDefault,
    rules: []const Rule,

    // The pack's `time_default` for a report's `track.source_id`, if any.
    pub fn timeDefaultOf(self: Pack, source: []const u8) ?TimeDefault {
        for (self.time_default) |d| {
            if (std.mem.eql(u8, d.source, source)) return d;
        }
        return null;
    }
};

pub const Error = error{
    UnknownDirective,
    RepeatedDirective,
    MissingDirective,
    WrongValueCount,
    ParamWithoutEquals,
    RepeatedParam,
    UnknownParam,
    MissingParam,
    NotANumber,
    NotAnInteger,
    BadValue,
    BadRuleName,
    RepeatedRuleName,
    ControlCharacter,
} || Allocator.Error;

const Directive = enum { pack, version, filter, window, time_default, rule };

// "Values": a number is written `-?[0-9]+(\.[0-9]+)?`, read as the nearest binary64.
fn parseNumber(s: []const u8) Error!f64 {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    const int_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == int_start) return error.NotANumber;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == frac_start) return error.NotANumber;
    }
    if (i != s.len) return error.NotANumber;
    const x = std.fmt.parseFloat(f64, s) catch return error.NotANumber;
    // A number whose nearest binary64 is infinite is a load error.
    if (!std.math.isFinite(x)) return error.NotANumber;
    return x;
}

// "Values": an integer is written `[0-9]+`.
fn parseInteger(s: []const u8) Error!i64 {
    if (s.len == 0) return error.NotAnInteger;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.NotAnInteger;
    return std.fmt.parseInt(i64, s, 10) catch error.NotAnInteger;
}

// "Values": a rule name is one or more of `A-Z a-z 0-9 . _ -`.
fn validRuleName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

// `name=value` parameters of a `filter`, `window` or `rule` line. A parameter
// without `=`, a repeated one, or one not in `allowed` is a load error.
const Params = struct {
    names: []const []const u8,
    values: [8]?[]const u8 = .{null} ** 8,

    fn read(allowed: []const []const u8, tokens: []const []const u8) Error!Params {
        std.debug.assert(allowed.len <= 8);
        var p = Params{ .names = allowed };
        for (tokens) |tok| {
            const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.ParamWithoutEquals;
            const name = tok[0..eq];
            const idx = for (allowed, 0..) |a, i| {
                if (std.mem.eql(u8, a, name)) break i;
            } else return error.UnknownParam;
            if (p.values[idx] != null) return error.RepeatedParam;
            p.values[idx] = tok[eq + 1 ..];
        }
        return p;
    }

    fn optional(p: Params, name: []const u8) ?[]const u8 {
        for (p.names, 0..) |a, i| if (std.mem.eql(u8, a, name)) return p.values[i];
        unreachable;
    }

    fn required(p: Params, name: []const u8) Error![]const u8 {
        return p.optional(name) orelse error.MissingParam;
    }
};

fn parseFilter(tokens: []const []const u8) Error!Filter {
    const p = try Params.read(&.{ "accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms" }, tokens);
    // Every parameter is required; check presence before parsing any value.
    for (p.names) |n| _ = try p.required(n);
    const f = Filter{
        .accel_var = try parseNumber(try p.required("accel_var")),
        .default_ce_m = try parseNumber(try p.required("default_ce_m")),
        .vel_sigma_ms = try parseNumber(try p.required("vel_sigma_ms")),
        .unknown_vel_ms = try parseNumber(try p.required("unknown_vel_ms")),
    };
    // `accel_var` below 0; `default_ce_m`, `vel_sigma_ms` or `unknown_vel_ms` 0 or below.
    if (f.accel_var < 0 or f.default_ce_m <= 0 or f.vel_sigma_ms <= 0 or f.unknown_vel_ms <= 0) return error.BadValue;
    return f;
}

fn parseWindow(tokens: []const []const u8) Error!Window {
    const p = try Params.read(&.{ "window_ms", "min_samples", "forget_ms" }, tokens);
    for (p.names) |n| _ = try p.required(n);
    const w = Window{
        .window_ms = try parseInteger(try p.required("window_ms")),
        .min_samples = try parseInteger(try p.required("min_samples")),
        .forget_ms = try parseInteger(try p.required("forget_ms")),
    };
    // Any value below 1.
    if (w.window_ms < 1 or w.min_samples < 1 or w.forget_ms < 1) return error.BadValue;
    return w;
}

// `rule <name> scope=<s> measure=<m> op=<op> limit=<x> for=<n> clear=<x> action=<a> [factor=<f>]`
fn parseRule(tokens: []const []const u8, earlier: []const Rule) Error!Rule {
    if (tokens.len == 0 or !validRuleName(tokens[0])) return error.BadRuleName;
    const name = tokens[0];
    for (earlier) |r| if (std.mem.eql(u8, r.name, name)) return error.RepeatedRuleName;

    const p = try Params.read(&.{ "scope", "measure", "op", "limit", "for", "clear", "action", "factor" }, tokens[1..]);
    for (p.names[0..7]) |n| _ = try p.required(n);

    const scope = std.meta.stringToEnum(Scope, try p.required("scope")) orelse return error.BadValue;
    const measure = std.meta.stringToEnum(Measure, try p.required("measure")) orelse return error.BadValue;
    if (!inScope(measure, scope)) return error.BadValue;
    const op = Op.parse(try p.required("op")) orelse return error.BadValue;
    const action = std.meta.stringToEnum(Action, try p.required("action")) orelse return error.BadValue;
    const limit = try parseNumber(try p.required("limit"));
    const clear = try parseNumber(try p.required("clear"));
    const for_n = try parseInteger(try p.required("for"));
    if (for_n < 1) return error.BadValue;

    // `clear` above `limit` for `>`/`>=`; below `limit` for `<`/`<=`.
    switch (op) {
        .gt, .ge => if (clear > limit) return error.BadValue,
        .lt, .le => if (clear < limit) return error.BadValue,
    }

    // `downgrade` without `factor`; `factor` with another action; `factor` not a number or below 1.
    var factor: ?f64 = null;
    if (p.optional("factor")) |fs| {
        if (action != .downgrade) return error.BadValue;
        factor = try parseNumber(fs);
        if (factor.? < 1) return error.BadValue;
    } else if (action == .downgrade) return error.MissingParam;

    return .{
        .name = name,
        .scope = scope,
        .measure = measure,
        .op = op,
        .limit = limit,
        .for_n = for_n,
        .clear = clear,
        .action = action,
        .factor = factor,
    };
}

// `time_default <source_id> error_ms=<ms> state=<state>`: the grammar of
// correlate.md 0.8 "Pack", with `error_ms` a number of this pack's grammar.
// No source id (a first token holding `=`), no parameter, a parameter other
// than `error_ms` and `state`, `error_ms` below 0 or `state` not one of the
// three states is a load error. A repeated source id is checked by the caller.
fn parseTimeDefault(tokens: []const []const u8) Error!TimeDefault {
    if (tokens.len == 0 or std.mem.indexOfScalar(u8, tokens[0], '=') != null) return error.BadValue;
    const p = try Params.read(&.{ "error_ms", "state" }, tokens[1..]);
    var out = TimeDefault{ .source = tokens[0], .error_ms = null, .state = null };
    if (p.optional("error_ms") == null and p.optional("state") == null) return error.MissingParam;
    if (p.optional("error_ms")) |text| {
        out.error_ms = try parseNumber(text);
        if (out.error_ms.? < 0) return error.BadValue;
    }
    if (p.optional("state")) |text| {
        out.state = std.meta.stringToEnum(TimeState, text) orelse return error.BadValue;
    }
    return out;
}

// "Pack", step 2: a control character is U+0000 to U+001F other than tab, or U+007F.
fn isControl(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7f;
}

// Parses the text of a pack.def. Returned slices point into `text`.
pub fn parse(alloc: Allocator, text: []const u8) Error!Pack {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var filter: ?Filter = null;
    var window: ?Window = null;
    var rules = std.ArrayList(Rule).init(alloc);
    var time_default = std.ArrayList(TimeDefault).init(alloc);

    // "Pack", step 1: lines end at LF; a final LF does not start another line.
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        // Step 1: one CR at the end of a line is removed.
        const raw = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        // Step 2: any control character left, a CR included, is a load error.
        for (raw) |c| if (isControl(c)) return error.ControlCharacter;
        // Step 3: `#` starts a comment. Steps 4 and 5: tokens are separated by
        // runs of space and tab only; a line with no token is ignored.
        const line = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        var toks = std.ArrayList([]const u8).init(alloc);
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |t| try toks.append(t);
        if (toks.items.len == 0) continue;

        const directive = std.meta.stringToEnum(Directive, toks.items[0]) orelse return error.UnknownDirective;
        const args = toks.items[1..];
        switch (directive) {
            .pack, .version => {
                const slot = if (directive == .pack) &name else &version;
                if (slot.* != null) return error.RepeatedDirective;
                if (args.len != 1) return error.WrongValueCount;
                slot.* = args[0];
            },
            .filter => {
                if (filter != null) return error.RepeatedDirective;
                filter = try parseFilter(args);
            },
            .window => {
                if (window != null) return error.RepeatedDirective;
                window = try parseWindow(args);
            },
            .time_default => {
                const td = try parseTimeDefault(args);
                for (time_default.items) |prev| {
                    if (std.mem.eql(u8, prev.source, td.source)) return error.RepeatedDirective;
                }
                try time_default.append(td);
            },
            .rule => try rules.append(try parseRule(args, rules.items)),
        }
    }

    return .{
        .name = name orelse return error.MissingDirective,
        .version = version orelse return error.MissingDirective,
        .filter = filter orelse return error.MissingDirective,
        .window = window orelse return error.MissingDirective,
        .time_default = time_default.items,
        .rules = rules.items,
    };
}

// spec/quality.md operation `load_pack(dir)`: reads `<dir>/pack.def`.
pub fn load(alloc: Allocator, dir: []const u8) !Pack {
    return parse(alloc, try json_read.readPackDef(alloc, dir));
}

test "a quality pack, its rules and its load errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "pack q\r\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=1000 min_samples=2 forget_ms=5000\n";
    const p = try parse(a, head ++ "time_default s error_ms=5\nrule slow scope=entity measure=age op=> limit=10 for=2 clear=5 action=downgrade factor=2\n");
    try std.testing.expectEqual(@as(usize, 1), p.rules.len);
    try std.testing.expectEqual(@as(f64, 2), p.rules[0].factor.?);
    try std.testing.expectEqual(@as(f64, 5), p.timeDefaultOf("s").?.error_ms.?);
    try std.testing.expectEqual(Op.ge, Op.parse(">=").?);
    try std.testing.expect(Op.lt.holds(1, 2) and Op.le.clears(3, 2) and !Op.gt.clears(3, 2));
    try std.testing.expect(inScope(.entities, .source) and !inScope(.entities, .entity));
    try std.testing.expectEqual(@as(i64, 2), timeStateCode(.@"free-running"));
    try std.testing.expectError(error.BadValue, parse(a, head ++ "rule r scope=entity measure=entities op=> limit=1 for=1 clear=0 action=mark\n"));
    try std.testing.expectError(error.BadValue, parse(a, head ++ "rule r scope=entity measure=age op=> limit=1 for=1 clear=2 action=mark\n"));
    try std.testing.expectError(error.MissingParam, parse(a, head ++ "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=downgrade\n"));
    try std.testing.expectError(error.BadValue, parse(a, head ++ "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=mark factor=2\n"));
    try std.testing.expectError(error.BadRuleName, parse(a, head ++ "rule a/b scope=entity\n"));
    try std.testing.expectError(error.RepeatedRuleName, parse(a, head ++ "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=mark\nrule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=mark\n"));
    try std.testing.expectError(error.ControlCharacter, parse(a, head ++ "\x01\n"));
    try std.testing.expectError(error.NotANumber, parse(a, head ++ "time_default s error_ms=1e3\n"));
    try std.testing.expectError(error.MissingParam, parse(a, head ++ "time_default s\n"));
    try std.testing.expectError(error.NotAnInteger, parse(a, "pack q\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=x min_samples=2 forget_ms=5000\n"));
    try std.testing.expectError(error.MissingDirective, parse(a, "pack q\nversion 1\n"));
}
