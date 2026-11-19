// Spec "Pack": parsing of pack.def.
const std = @import("std");
const Allocator = std.mem.Allocator;

// Spec "Tests": each test's parameter names are the payload's field names.
pub const Test = union(enum) {
    distance: struct { max_m: f64 },
    window: struct { multiplier: f64, window_m: f64, err_min_m: f64, err_max_m: f64 },
    mahalanobis: struct { gate: f64 },
    course: struct { max_deg: f64, min_speed_ms: f64 },
    speed: struct { max_pct: f64, min_speed_ms: f64 },
    altitude: struct { max_m: f64 },
    same: struct { key: []const u8 },
};

// Spec "Track estimate": the `filter` line.
pub const Filter = struct {
    accel_var: f64,
    default_ce_m: f64,
    vel_sigma_ms: f64,
    unknown_vel_ms: f64,
};

pub const Output = enum { priority, latest };

// Spec "Pack": `method confirm` (correlate.md) or `method assign` (correlate-assign.md).
pub const Method = enum { confirm, assign };

pub const Priority = struct { source: []const u8, n: f64 };

pub const Pack = struct {
    name: []const u8,
    version: []const u8,
    method: Method,
    filter: Filter,
    gate: []const Test,
    confirm: []const Test,
    hold: []const Test,
    confirm_count: i64,
    hold_failures: i64,
    stale_ms: i64,
    same_source_allow: bool,
    output: Output,
    priority: []const Priority,
    // correlate-assign.md "Pack".
    new_cost: f64,
    keep_bonus: f64,

    // Spec "Fused output": 100 for a source the pack does not list.
    pub fn priorityOf(self: Pack, source: []const u8) f64 {
        for (self.priority) |p| {
            if (std.mem.eql(u8, p.source, source)) return p.n;
        }
        return 100;
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

const Directive = enum {
    pack,
    version,
    method,
    filter,
    gate,
    confirm,
    hold,
    confirm_count,
    hold_failures,
    stale_ms,
    same_source,
    output,
    priority,
    new_cost,
    keep_bonus,
};

// Spec "Pack": `gate`, `confirm`, `hold` and `priority` repeat.
fn repeats(d: Directive) bool {
    return switch (d) {
        .gate, .confirm, .hold, .priority => true,
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

fn parseDecimal(s: []const u8) Error!f64 {
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

fn parseTest(alloc: Allocator, tokens: []const []const u8) Error!Test {
    if (tokens.len == 0) return error.WrongArgumentCount;
    inline for (@typeInfo(Test).Union.fields) |f| {
        if (std.mem.eql(u8, f.name, tokens[0])) {
            return @unionInit(Test, f.name, try parseParams(f.type, alloc, tokens[1..]));
        }
    }
    return error.UnknownTest;
}

fn one(args: []const []const u8) Error![]const u8 {
    if (args.len != 1) return error.WrongArgumentCount;
    return args[0];
}

pub fn parse(alloc: Allocator, text: []const u8) Error!Pack {
    var seen = std.EnumSet(Directive).initEmpty();
    var gate = std.ArrayList(Test).init(alloc);
    var confirm = std.ArrayList(Test).init(alloc);
    var hold = std.ArrayList(Test).init(alloc);
    var priority = std.ArrayList(Priority).init(alloc);
    var pack: Pack = .{
        .name = "",
        .version = "",
        .method = .confirm,
        .filter = undefined,
        .gate = &.{},
        .confirm = &.{},
        .hold = &.{},
        .confirm_count = 0,
        .hold_failures = 0,
        .stale_ms = 0,
        .same_source_allow = false,
        .output = .priority,
        .priority = &.{},
        .new_cost = 0,
        .keep_bonus = 0,
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
            .method => pack.method = std.meta.stringToEnum(Method, try one(args)) orelse return error.BadValue,
            .new_cost => pack.new_cost = try parseDecimal(try one(args)),
            .keep_bonus => pack.keep_bonus = try parseDecimal(try one(args)),
            .filter => pack.filter = try parseParams(Filter, alloc, args),
            .gate => try gate.append(try parseTest(alloc, args)),
            .confirm => try confirm.append(try parseTest(alloc, args)),
            .hold => try hold.append(try parseTest(alloc, args)),
            .confirm_count => pack.confirm_count = try parseCount(try one(args)),
            .hold_failures => pack.hold_failures = try parseCount(try one(args)),
            .stale_ms => pack.stale_ms = try parseCount(try one(args)),
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

    switch (pack.method) {
        .confirm => {
            const required = [_]Directive{ .pack, .version, .filter, .confirm_count, .hold_failures, .stale_ms };
            for (required) |r| if (!seen.contains(r)) return error.MissingDirective;
            // correlate-assign.md directives are not directives of correlate.md.
            const refused = [_]Directive{ .new_cost, .keep_bonus };
            for (refused) |r| if (seen.contains(r)) return error.DirectiveNotForMethod;
        },
        .assign => {
            // correlate-assign.md "Pack": all but `gate` are required.
            const required = [_]Directive{ .pack, .version, .filter, .new_cost, .keep_bonus, .stale_ms };
            for (required) |r| if (!seen.contains(r)) return error.MissingDirective;
            const refused = [_]Directive{ .confirm, .hold, .confirm_count, .hold_failures, .same_source, .output, .priority };
            for (refused) |r| if (seen.contains(r)) return error.DirectiveNotForMethod;
            // correlate-assign.md 0.2 "Pack": ranges of `new_cost` and `keep_bonus`.
            if (!(pack.new_cost > 0 and pack.keep_bonus >= 0)) return error.BadValue;
        },
    }

    pack.gate = try gate.toOwnedSlice();
    pack.confirm = try confirm.toOwnedSlice();
    pack.hold = try hold.toOwnedSlice();
    pack.priority = try priority.toOwnedSlice();
    return pack;
}

// Spec operation `load_pack(dir)`.
pub fn load(alloc: Allocator, dir: []const u8) !Pack {
    const path = try std.fs.path.join(alloc, &.{ dir, "pack.def" });
    const text = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 20);
    return parse(alloc, text);
}
