// spec/filter.md "Pack": parsing of a filter pack.def and its load errors.
const std = @import("std");
const json_read = @import("../io/json_read.zig");
const Allocator = std.mem.Allocator;

pub const Action = enum { keep, drop };

pub const Vertex = struct { lat: f64, lon: f64 };

// spec/filter.md "Conditions", "Ranges": an omitted bound is null.
pub const Range = struct { min: ?f64, max: ?f64 };

// A pack text compared with a report value ("`key` equality"): the text, and
// its binary64 value when the text is a pack number.
pub const Text = struct { text: []const u8, number: ?f64 };

pub const Key = struct {
    name: []const u8,
    form: union(enum) {
        eq: Text,
        in: []const Text,
        range: Range,
    },
};

// One condition and its parameters, as in the "Parameter sets" table.
pub const Condition = union(enum) {
    circle: struct { lat: f64, lon: f64, radius_m: f64 },
    polygon: struct { vertices: []const Vertex },
    near: struct { reference: []const u8, radius_m: f64, max_age_ms: i64 },
    env: struct { in: []const []const u8 },
    affiliation: struct { in: []const []const u8 },
    source: struct { in: []const []const u8 },
    uid: struct { in: []const []const u8 },
    key: Key,
    has: struct { name: []const u8 },
    speed: Range,
    altitude: Range,
    interval: struct { min_ms: i64 },
    order: void,
};

pub const When = struct { negated: bool, condition: Condition };

pub const Rule = struct {
    name: []const u8,
    action: Action,
    conditions: []const When,
};

pub const Pack = struct {
    name: []const u8,
    version: []const u8,
    default: Action,
    forget_ms: i64,
    rules: []const Rule,
};

pub const Error = error{
    UnknownDirective,
    RepeatedDirective,
    MissingDirective,
    WrongArgumentCount,
    BadAction,
    WhenBeforeRule,
    RuleWithoutWhen,
    RepeatedRuleName,
    RuleNamedDefault,
    UnknownCondition,
    ParamWithoutEquals,
    RepeatedParam,
    UnknownParam,
    MissingParam,
    BadValue,
} || Allocator.Error;

const Directive = enum { pack, version, default, forget_ms, rule, when };

// ---- Values ------------------------------------------------------------------

// number: `-?[0-9]+(\.[0-9]+)?`, read as the nearest binary64.
pub fn isPackNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    const int_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == int_start) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == frac_start) return false;
    }
    return i == s.len;
}

fn number(s: []const u8) Error!f64 {
    if (!isPackNumber(s)) return error.BadValue;
    return std.fmt.parseFloat(f64, s) catch error.BadValue;
}

// integer: `[0-9]+`, at most 9223372036854775807.
fn integer(s: []const u8) Error!i64 {
    if (s.len == 0) return error.BadValue;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.BadValue;
    return std.fmt.parseInt(i64, s, 10) catch error.BadValue;
}

fn latitude(s: []const u8) Error!f64 {
    const x = try number(s);
    if (x < -90 or x > 90) return error.BadValue;
    return x;
}

fn longitude(s: []const u8) Error!f64 {
    const x = try number(s);
    if (x < -180 or x > 180) return error.BadValue;
    return x;
}

fn nonNegative(x: f64) Error!f64 {
    if (x < 0) return error.BadValue;
    return x;
}

fn aboveZero(x: i64) Error!i64 {
    if (x <= 0) return error.BadValue;
    return x;
}

// `reference`, `name`, `eq`: a non-empty token.
fn token(s: []const u8) Error![]const u8 {
    if (s.len == 0) return error.BadValue;
    return s;
}

// `in`: one or more non-empty items separated by `,`.
fn list(alloc: Allocator, s: []const u8) Error![]const []const u8 {
    var items = std.ArrayList([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |item| {
        if (item.len == 0) return error.BadValue;
        try items.append(item);
    }
    return items.toOwnedSlice();
}

// `vertices`: `<lat>,<lon>;<lat>,<lon>;...` with at least three pairs.
fn vertices(alloc: Allocator, s: []const u8) Error![]const Vertex {
    var out = std.ArrayList(Vertex).init(alloc);
    var pairs = std.mem.splitScalar(u8, s, ';');
    while (pairs.next()) |pair| {
        const comma = std.mem.indexOfScalar(u8, pair, ',') orelse return error.BadValue;
        try out.append(.{ .lat = try latitude(pair[0..comma]), .lon = try longitude(pair[comma + 1 ..]) });
    }
    if (out.items.len < 3) return error.BadValue;
    return out.toOwnedSlice();
}

fn text(s: []const u8) Text {
    const n: ?f64 = if (isPackNumber(s)) std.fmt.parseFloat(f64, s) catch null else null;
    return .{ .text = s, .number = n };
}

fn texts(alloc: Allocator, s: []const u8) Error![]const Text {
    const items = try list(alloc, s);
    const out = try alloc.alloc(Text, items.len);
    for (items, out) |item, *t| t.* = text(item);
    return out;
}

// ---- Parameters ----------------------------------------------------------------

// The `name=value` parameters of one `when` line. The name is the text before
// the first `=`; a parameter without `=` or given twice is a load error.
const Params = struct {
    names: []const []const u8,
    values: []const []const u8,
    used: []bool,

    fn init(alloc: Allocator, args: []const []const u8) Error!Params {
        const names = try alloc.alloc([]const u8, args.len);
        const values = try alloc.alloc([]const u8, args.len);
        const used = try alloc.alloc(bool, args.len);
        for (args, 0..) |arg, i| {
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.ParamWithoutEquals;
            names[i] = arg[0..eq];
            values[i] = arg[eq + 1 ..];
            used[i] = false;
            for (names[0..i]) |earlier| if (std.mem.eql(u8, earlier, names[i])) return error.RepeatedParam;
        }
        return .{ .names = names, .values = values, .used = used };
    }

    fn optional(self: Params, name: []const u8) ?[]const u8 {
        for (self.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) {
                self.used[i] = true;
                return self.values[i];
            }
        }
        return null;
    }

    fn required(self: Params, name: []const u8) Error![]const u8 {
        return self.optional(name) orelse error.MissingParam;
    }

    // A parameter the condition does not take is a load error.
    fn finish(self: Params) Error!void {
        for (self.used) |u| if (!u) return error.UnknownParam;
    }
};

// `min` and/or `max`; when both are given, `min <= max`.
fn range(p: Params) Error!Range {
    const lo: ?f64 = if (p.optional("min")) |s| try number(s) else null;
    const hi: ?f64 = if (p.optional("max")) |s| try number(s) else null;
    if (lo == null and hi == null) return error.MissingParam;
    if (lo != null and hi != null and lo.? > hi.?) return error.BadValue;
    return .{ .min = lo, .max = hi };
}

fn condition(alloc: Allocator, name: []const u8, p: Params) Error!Condition {
    const c: Condition = if (std.mem.eql(u8, name, "circle")) .{ .circle = .{
        .lat = try latitude(try p.required("lat")),
        .lon = try longitude(try p.required("lon")),
        .radius_m = try nonNegative(try number(try p.required("radius_m"))),
    } } else if (std.mem.eql(u8, name, "polygon")) .{ .polygon = .{
        .vertices = try vertices(alloc, try p.required("vertices")),
    } } else if (std.mem.eql(u8, name, "near")) .{ .near = .{
        .reference = try token(try p.required("reference")),
        .radius_m = try nonNegative(try number(try p.required("radius_m"))),
        .max_age_ms = try integer(try p.required("max_age_ms")),
    } } else if (std.mem.eql(u8, name, "env"))
        .{ .env = .{ .in = try list(alloc, try p.required("in")) } }
    else if (std.mem.eql(u8, name, "affiliation"))
        .{ .affiliation = .{ .in = try list(alloc, try p.required("in")) } }
    else if (std.mem.eql(u8, name, "source"))
        .{ .source = .{ .in = try list(alloc, try p.required("in")) } }
    else if (std.mem.eql(u8, name, "uid"))
        .{ .uid = .{ .in = try list(alloc, try p.required("in")) } }
    else if (std.mem.eql(u8, name, "key"))
        .{ .key = try keyCondition(alloc, p) }
    else if (std.mem.eql(u8, name, "has"))
        .{ .has = .{ .name = try token(try p.required("name")) } }
    else if (std.mem.eql(u8, name, "speed"))
        .{ .speed = try range(p) }
    else if (std.mem.eql(u8, name, "altitude"))
        .{ .altitude = try range(p) }
    else if (std.mem.eql(u8, name, "interval"))
        .{ .interval = .{ .min_ms = try aboveZero(try integer(try p.required("min_ms"))) } }
    else if (std.mem.eql(u8, name, "order"))
        .{ .order = {} }
    else
        return error.UnknownCondition;
    try p.finish();
    return c;
}

// `key`: `name` and one of: `eq`; `in`; `min`; `max`; `min` and `max`.
fn keyCondition(alloc: Allocator, p: Params) Error!Key {
    const name = try token(try p.required("name"));
    if (p.optional("eq")) |eq| {
        // Any other parameter is left unused and refused by `finish`.
        return .{ .name = name, .form = .{ .eq = text(try token(eq)) } };
    }
    if (p.optional("in")) |in| {
        return .{ .name = name, .form = .{ .in = try texts(alloc, in) } };
    }
    return .{ .name = name, .form = .{ .range = try range(p) } };
}

// ---- pack.def ------------------------------------------------------------------

fn action(s: []const u8) Error!Action {
    return std.meta.stringToEnum(Action, s) orelse error.BadAction;
}

fn one(args: []const []const u8) Error![]const u8 {
    if (args.len != 1) return error.WrongArgumentCount;
    return args[0];
}

const RuleBuilder = struct {
    name: []const u8,
    action: Action,
    conditions: std.ArrayList(When),
};

pub fn parse(alloc: Allocator, def: []const u8) Error!Pack {
    var seen = std.EnumSet(Directive).initEmpty();
    var pack: Pack = .{ .name = "", .version = "", .default = .keep, .forget_ms = 0, .rules = &.{} };
    var rules = std.ArrayList(RuleBuilder).init(alloc);
    var tokens = std.ArrayList([]const u8).init(alloc);

    var lines = std.mem.splitScalar(u8, def, '\n');
    while (lines.next()) |raw| {
        // `#` starts a comment; arguments are separated by spaces or tabs.
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        tokens.clearRetainingCapacity();
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |t| try tokens.append(try alloc.dupe(u8, t));
        if (tokens.items.len == 0) continue;

        const d = std.meta.stringToEnum(Directive, tokens.items[0]) orelse return error.UnknownDirective;
        const args = tokens.items[1..];
        if (d != .rule and d != .when) {
            if (seen.contains(d)) return error.RepeatedDirective;
            seen.insert(d);
        }
        switch (d) {
            .pack => pack.name = try one(args),
            .version => pack.version = try one(args),
            .default => pack.default = try action(try one(args)),
            .forget_ms => pack.forget_ms = try aboveZero(try integer(try one(args))),
            .rule => {
                if (args.len != 2) return error.WrongArgumentCount;
                const name = args[0];
                if (std.mem.eql(u8, name, "default")) return error.RuleNamedDefault;
                for (rules.items) |r| if (std.mem.eql(u8, r.name, name)) return error.RepeatedRuleName;
                try rules.append(.{ .name = name, .action = try action(args[1]), .conditions = std.ArrayList(When).init(alloc) });
            },
            .when => {
                if (rules.items.len == 0) return error.WhenBeforeRule;
                var rest = args;
                const negated = rest.len > 0 and std.mem.eql(u8, rest[0], "not");
                if (negated) rest = rest[1..];
                if (rest.len == 0) return error.UnknownCondition;
                const params = try Params.init(alloc, rest[1..]);
                const c = try condition(alloc, rest[0], params);
                try rules.items[rules.items.len - 1].conditions.append(.{ .negated = negated, .condition = c });
            },
        }
    }

    for ([_]Directive{ .pack, .version, .default, .forget_ms }) |r| {
        if (!seen.contains(r)) return error.MissingDirective;
    }
    const out = try alloc.alloc(Rule, rules.items.len);
    for (rules.items, out) |*r, *o| {
        if (r.conditions.items.len == 0) return error.RuleWithoutWhen;
        o.* = .{ .name = r.name, .action = r.action, .conditions = try r.conditions.toOwnedSlice() };
    }
    pack.rules = out;
    return pack;
}

// Operation `load_pack(dir)`.
pub fn load(alloc: Allocator, dir: []const u8) !Pack {
    return parse(alloc, try json_read.readPackDef(alloc, dir));
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "a filter pack with every condition, and its load errors" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const head = "pack f\nversion 1\ndefault keep\nforget_ms 1000\n";
        const p = try parse(a, head ++
            \\rule r1 drop
            \\when circle lat=1 lon=2 radius_m=3
            \\when not polygon vertices=0,0;0,1;1,1
            \\when near reference=s/u radius_m=10 max_age_ms=5
            \\when env in=A,S
            \\when affiliation in=h
            \\when source in=s
            \\when uid in=u
            \\when key name=x eq=1.5
            \\when key name=x in=a,2
            \\when key name=x min=1
            \\when has name=hae
            \\when speed max=3
            \\when altitude min=1 max=2
            \\when interval min_ms=10
            \\when order
        );
        try std.testing.expectEqual(@as(usize, 15), p.rules[0].conditions.len);
        try std.testing.expect(p.rules[0].conditions[1].negated);
        try std.testing.expectEqual(@as(f64, 1.5), p.rules[0].conditions[7].condition.key.form.eq.number.?);
        try std.testing.expectError(error.WhenBeforeRule, parse(a, head ++ "when order"));
        try std.testing.expectError(error.RuleWithoutWhen, parse(a, head ++ "rule r keep"));
        try std.testing.expectError(error.RuleNamedDefault, parse(a, head ++ "rule default keep\nwhen order"));
        try std.testing.expectError(error.RepeatedRuleName, parse(a, head ++ "rule r keep\nwhen order\nrule r drop\nwhen order"));
        try std.testing.expectError(error.BadAction, parse(a, head ++ "rule r maybe\nwhen order"));
        try std.testing.expectError(error.UnknownCondition, parse(a, head ++ "rule r keep\nwhen nearby"));
        try std.testing.expectError(error.UnknownParam, parse(a, head ++ "rule r keep\nwhen order x=1"));
        try std.testing.expectError(error.MissingParam, parse(a, head ++ "rule r keep\nwhen speed"));
        try std.testing.expectError(error.BadValue, parse(a, head ++ "rule r keep\nwhen speed min=2 max=1"));
        try std.testing.expectError(error.BadValue, parse(a, head ++ "rule r keep\nwhen circle lat=91 lon=0 radius_m=1"));
        try std.testing.expectError(error.BadValue, parse(a, head ++ "rule r keep\nwhen polygon vertices=0,0;1,1"));
        try std.testing.expectError(error.RepeatedParam, parse(a, head ++ "rule r keep\nwhen speed min=1 min=2"));
        try std.testing.expectError(error.ParamWithoutEquals, parse(a, head ++ "rule r keep\nwhen speed min"));
        try std.testing.expectError(error.MissingDirective, parse(a, "pack f\nversion 1\ndefault keep\n"));
        try std.testing.expectError(error.BadValue, parse(a, "pack f\nversion 1\ndefault keep\nforget_ms 0\n"));
    }
};
