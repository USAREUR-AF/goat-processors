// spec/fuse.md "Pack": parsing of a fuse pack.def.
const std = @import("std");
const json_read = @import("../io/json_read.zig");
const Allocator = std.mem.Allocator;
const params = @import("../model/params.zig");

// The `filter` line is the one of correlate.md "Track estimate".
pub const Filter = params.Filter;

// spec/fuse.md "Kinematics": the five methods.
pub const Kinematics = enum { inverse_variance, covariance_intersection, best, priority, latest };

// spec/fuse.md "Attributes": the five rules.
pub const Rule = enum { priority, latest, majority, max, min };

pub const Attribute = struct { key: []const u8, rule: Rule };

pub const Pack = struct {
    name: []const u8,
    version: []const u8,
    filter: Filter,
    kinematics: Kinematics,
    // In pack order.
    attributes: []const Attribute,
    // In line order, which is rank order.
    sources: []const []const u8,
    stale_ms: i64,

    // spec/fuse.md "Kinematics", Rank: the index of the source among the
    // `source` lines, or null when the source is not listed.
    pub fn rank(self: Pack, source: []const u8) ?usize {
        for (self.sources, 0..) |s, i| {
            if (std.mem.eql(u8, s, source)) return i;
        }
        return null;
    }

    // For comparisons: an unlisted source ranks after every listed source.
    pub fn rankOrder(self: Pack, source: []const u8) usize {
        return self.rank(source) orelse self.sources.len;
    }
};

pub const Error = error{
    UnknownDirective,
    MissingDirective,
    RepeatedDirective,
    WrongValueCount,
    ParamWithoutEquals,
    UnknownParam,
    RepeatedParam,
    MissingParam,
    NotANumber,
    BreaksRule,
    RepeatedKey,
} || Allocator.Error;

const Directive = enum { pack, version, filter, kinematics, attribute, source, stale_ms };

// A **number**: optional `-`, one or more digits, optionally `.` and one or
// more digits, optionally `e`/`E`, an optional sign and one or more digits.
fn isNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    i = skipDigits(s, i) orelse return false;
    if (i < s.len and s[i] == '.') i = skipDigits(s, i + 1) orelse return false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        i = skipDigits(s, i) orelse return false;
    }
    return i == s.len;
}

// Index after one or more digits starting at `i`, or null when there are none.
fn skipDigits(s: []const u8, start: usize) ?usize {
    var i = start;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return if (i == start) null else i;
}

fn parseNumber(s: []const u8) Error!f64 {
    if (!isNumber(s)) return error.NotANumber;
    return std.fmt.parseFloat(f64, s) catch error.NotANumber;
}

// An **integer**: one or more digits.
fn parseInteger(s: []const u8) Error!i64 {
    if (skipDigits(s, 0) != s.len) return error.NotANumber;
    return std.fmt.parseInt(i64, s, 10) catch error.NotANumber;
}

fn one(values: []const []const u8) Error![]const u8 {
    if (values.len != 1) return error.WrongValueCount;
    return values[0];
}

// `filter`: exactly the four parameters, each `name=value`, each a number;
// `default_ce_m`, `vel_sigma_ms`, `unknown_vel_ms` above 0, `accel_var` 0 or above.
fn parseFilter(values: []const []const u8) Error!Filter {
    const names = [_][]const u8{ "accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms" };
    var got = [_]?f64{null} ** names.len;
    for (values) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.ParamWithoutEquals;
        const name = tok[0..eq];
        const idx = for (names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) break i;
        } else return error.UnknownParam;
        if (got[idx] != null) return error.RepeatedParam;
        got[idx] = try parseNumber(tok[eq + 1 ..]);
    }
    for (got) |g| if (g == null) return error.MissingParam;
    const f = Filter{ .accel_var = got[0].?, .default_ce_m = got[1].?, .vel_sigma_ms = got[2].?, .unknown_vel_ms = got[3].? };
    if (!(f.accel_var >= 0) or !(f.default_ce_m > 0) or !(f.vel_sigma_ms > 0) or !(f.unknown_vel_ms > 0)) return error.BreaksRule;
    return f;
}

// `attribute <key> rule=<rule>`: a key without `=`, then exactly `rule=<rule>`.
fn parseAttribute(values: []const []const u8) Error!Attribute {
    if (values.len != 2) return error.WrongValueCount;
    const key = values[0];
    if (std.mem.indexOfScalar(u8, key, '=') != null) return error.BreaksRule;
    const tok = values[1];
    const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.ParamWithoutEquals;
    if (!std.mem.eql(u8, tok[0..eq], "rule")) return error.UnknownParam;
    const rule = std.meta.stringToEnum(Rule, tok[eq + 1 ..]) orelse return error.BreaksRule;
    return .{ .key = key, .rule = rule };
}

pub fn parse(alloc: Allocator, text: []const u8) Error!Pack {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var filter: ?Filter = null;
    var kinematics: ?Kinematics = null;
    var stale_ms: ?i64 = null;
    var attributes = std.ArrayList(Attribute).init(alloc);
    var sources = std.ArrayList([]const u8).init(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        // A CR at the end of a line is removed; `#` starts a comment.
        var line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        if (std.mem.indexOfScalar(u8, line, '#')) |h| line = line[0..h];
        // Split on runs of spaces and tabs; a line with nothing left is ignored.
        var tokens = std.ArrayList([]const u8).init(alloc);
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |t| try tokens.append(t);
        if (tokens.items.len == 0) continue;

        const directive = std.meta.stringToEnum(Directive, tokens.items[0]) orelse return error.UnknownDirective;
        const values = tokens.items[1..];
        switch (directive) {
            .pack => {
                if (name != null) return error.RepeatedDirective;
                name = try alloc.dupe(u8, try one(values));
            },
            .version => {
                if (version != null) return error.RepeatedDirective;
                version = try alloc.dupe(u8, try one(values));
            },
            .filter => {
                if (filter != null) return error.RepeatedDirective;
                filter = try parseFilter(values);
            },
            .kinematics => {
                if (kinematics != null) return error.RepeatedDirective;
                kinematics = std.meta.stringToEnum(Kinematics, try one(values)) orelse return error.BreaksRule;
            },
            .stale_ms => {
                if (stale_ms != null) return error.RepeatedDirective;
                stale_ms = try parseInteger(try one(values));
            },
            .attribute => {
                var a = try parseAttribute(values);
                for (attributes.items) |prev| if (std.mem.eql(u8, prev.key, a.key)) return error.RepeatedKey;
                a.key = try alloc.dupe(u8, a.key);
                try attributes.append(a);
            },
            .source => {
                const s = try one(values);
                for (sources.items) |prev| if (std.mem.eql(u8, prev, s)) return error.RepeatedKey;
                try sources.append(try alloc.dupe(u8, s));
            },
        }
    }

    return .{
        .name = name orelse return error.MissingDirective,
        .version = version orelse return error.MissingDirective,
        .filter = filter orelse return error.MissingDirective,
        .kinematics = kinematics orelse return error.MissingDirective,
        .stale_ms = stale_ms orelse return error.MissingDirective,
        .attributes = attributes.items,
        .sources = sources.items,
    };
}

// `load_pack(dir)`: `<dir>/pack.def`.
pub fn load(alloc: Allocator, dir: []const u8) !Pack {
    return parse(alloc, try json_read.readPackDef(alloc, dir));
}

test "numbers and integers" {
    try std.testing.expect(isNumber("1"));
    try std.testing.expect(isNumber("-1.5e+3"));
    try std.testing.expect(isNumber("5.0E1"));
    try std.testing.expect(!isNumber("+1"));
    try std.testing.expect(!isNumber("1."));
    try std.testing.expect(!isNumber(".5"));
    try std.testing.expect(!isNumber("5x"));
    try std.testing.expectError(error.NotANumber, parseInteger("-1"));
    try std.testing.expectError(error.NotANumber, parseInteger("1000.0"));
}
