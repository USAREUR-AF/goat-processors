// spec/quality.md "Pack" and "Rules": parsing of a quality pack.def.
const std = @import("std");
const Allocator = std.mem.Allocator;
const correlate_pack = @import("pack.zig");

// spec/quality.md "Frame and filter": the `filter` line has the parameters of
// correlate.md "Track estimate", so the correlate type is reused.
pub const Filter = correlate_pack.Filter;

// The `window` line.
pub const Window = struct {
    window_ms: i64,
    min_samples: i64,
    forget_ms: i64,
};

pub const Scope = enum { entity, source };

// "Entity measures" and "Source measures", in the order of their tables.
// `entities` is a source measure only.
pub const Measure = enum {
    reports,
    interval_last,
    interval_mean,
    interval_max,
    age,
    latency_mean,
    latency_max,
    nis_mean,
    speed_err_mean,
    out_of_order,
    duplicate,
    missing_ce,
    missing_vel,
    missing_hae,
    entities,

    pub fn inScope(m: Measure, scope: Scope) bool {
        return m != .entities or scope == .source;
    }
};

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
    rules: []const Rule,
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
} || Allocator.Error;

const Directive = enum { pack, version, filter, window, rule };

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
    return std.fmt.parseFloat(f64, s) catch error.NotANumber;
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
    if (!measure.inScope(scope)) return error.BadValue;
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

// Parses the text of a pack.def. Returned slices point into `text`.
pub fn parse(alloc: Allocator, text: []const u8) Error!Pack {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var filter: ?Filter = null;
    var window: ?Window = null;
    var rules = std.ArrayList(Rule).init(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        // `#` starts a comment; tokens are separated by spaces or tabs; blank lines are ignored.
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
            .rule => try rules.append(try parseRule(args, rules.items)),
        }
    }

    return .{
        .name = name orelse return error.MissingDirective,
        .version = version orelse return error.MissingDirective,
        .filter = filter orelse return error.MissingDirective,
        .window = window orelse return error.MissingDirective,
        .rules = rules.items,
    };
}

// spec/quality.md operation `load_pack(dir)`: reads `<dir>/pack.def`.
pub fn load(alloc: Allocator, dir: []const u8) !Pack {
    const path = try std.fs.path.join(alloc, &.{ dir, "pack.def" });
    const text = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 20);
    return parse(alloc, text);
}
