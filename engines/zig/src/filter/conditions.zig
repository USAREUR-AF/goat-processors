// spec/filter.md "Conditions": the table, one branch per row. Each condition
// is evaluated from the report and the entities' state before the report;
// nothing is changed.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const fpack = @import("pack.zig");
const geo = @import("geo.zig");
const report_keys = @import("../model/report.zig");
const record = @import("../trace/record.zig");
const engine = @import("engine.zig");
const State = engine.State;
const Report = engine.Report;

fn strValue(s: []const u8) json.Value {
    return .{ .string = s };
}

// "Conditions": true (yes), false (no) or unknown.
pub const Truth = enum { yes, no, unknown };

fn truth(b: bool) Truth {
    return if (b) .yes else .no;
}

// One evaluated condition: its result before `not`, and the trace `value`/`limit`.
pub const Outcome = struct { result: Truth, value: json.Value, limit: json.Value };

// An integer for the trace; differences of two int64 are computed in i128.
pub fn intValue(x: i128) json.Value {
    if (std.math.cast(i64, x)) |i| return .{ .integer = i };
    return .{ .float = @floatFromInt(x) };
}

const asNumber = report_keys.asNumber;

// "Reports": the environment, the third `-`-separated element of `type`.
fn environment(type_: ?[]const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, type_ orelse return null, '-');
    _ = parts.next();
    _ = parts.next() orelse return null;
    return parts.next();
}

// "Reports": the affiliation, the second element when the first is exactly `a`.
fn affiliation(type_: ?[]const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, type_ orelse return null, '-');
    const first = parts.next().?;
    if (!std.mem.eql(u8, first, "a")) return null;
    return parts.next();
}

// "Absent and present": the report's value of key `name` after the
// optional-key rules of Reports, or null when absent.
fn present(m: json.ObjectMap, name: []const u8) ?json.Value {
    const v = m.get(name) orelse return null;
    if (v == .null) return null;
    const eql = std.mem.eql;
    if (eql(u8, name, "hae") or eql(u8, name, "course") or eql(u8, name, "speed_ms")) {
        if (report_keys.numberOf(m, name) == null) return null;
    } else if (eql(u8, name, "ce")) {
        if (report_keys.ceOf(m) == null) return null;
    } else if (eql(u8, name, "type")) {
        if (report_keys.stringOf(m, name) == null) return null;
    } else if (eql(u8, name, "stale_ms")) {
        if (report_keys.integerOf(m, name) == null) return null;
    }
    return v;
}

// "`key` equality" between a report value and a pack text.
fn keyEquals(v: json.Value, t: fpack.Text) bool {
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, t.text),
        .integer, .float, .number_string => if (t.number) |n| asNumber(v) == n else false,
        .bool => |b| std.mem.eql(u8, t.text, if (b) "true" else "false"),
        else => false,
    };
}

fn inRange(x: f64, r: fpack.Range) bool {
    if (r.min) |lo| if (x < lo) return false;
    if (r.max) |hi| if (x > hi) return false;
    return true;
}

fn textList(a: Allocator, items: []const fpack.Text) !json.Value {
    var arr = json.Array.init(a);
    for (items) |t| try arr.append(strValue(t.text));
    return .{ .array = arr };
}

fn rangeLimit(a: Allocator, r: fpack.Range) !json.Value {
    var arr = json.Array.init(a);
    try arr.append(record.toValue(r.min));
    try arr.append(record.toValue(r.max));
    return .{ .array = arr };
}

// "Conditions": the table, one branch per row.
pub fn evaluate(a: Allocator, entities: *const std.StringArrayHashMap(State), c: fpack.Condition, r: Report) !Outcome {
    const type_ = report_keys.stringOf(r.map, "type");
    switch (c) {
        .circle => |p| {
            const d = geo.distance(r.lat, r.lon, p.lat, p.lon);
            return .{ .result = truth(d <= p.radius_m), .value = .{ .float = d }, .limit = .{ .float = p.radius_m } };
        },
        .polygon => |p| {
            const side = geo.polygon(p.vertices, r.lat, r.lon);
            return .{ .result = truth(side != .outside), .value = strValue(side.name()), .limit = .null };
        },
        .near => |p| {
            const limit = json.Value{ .float = p.radius_m };
            const unknown = Outcome{ .result = .unknown, .value = .null, .limit = limit };
            // The reference's state before this report.
            const ref = entities.get(p.reference) orelse return unknown;
            // Stale by age, or by the reference's own `stale_ms`.
            const diff = @as(i128, r.time_ms) - ref.time_ms;
            const age = if (diff < 0) -diff else diff;
            if (age > p.max_age_ms) return unknown;
            if (ref.stale_ms) |s| if (r.time_ms >= s) return unknown;
            const at = geo.predict(ref.time_ms, ref.lat, ref.lon, ref.course, ref.speed_ms, r.time_ms);
            const d = geo.distance(r.lat, r.lon, at.lat, at.lon);
            return .{ .result = truth(d <= p.radius_m), .value = .{ .float = d }, .limit = limit };
        },
        .env => |p| return listCondition(a, environment(type_), p.in),
        .affiliation => |p| return listCondition(a, affiliation(type_), p.in),
        .source => |p| return listCondition(a, r.source, p.in),
        .uid => |p| return listCondition(a, r.uid, p.in),
        .key => |k| {
            const v = present(r.map, k.name);
            switch (k.form) {
                .eq => |t| {
                    const limit = strValue(t.text);
                    const val = v orelse return .{ .result = .unknown, .value = .null, .limit = limit };
                    return .{ .result = truth(keyEquals(val, t)), .value = val, .limit = limit };
                },
                .in => |items| {
                    const limit = try textList(a, items);
                    const val = v orelse return .{ .result = .unknown, .value = .null, .limit = limit };
                    var found = false;
                    for (items) |t| {
                        if (keyEquals(val, t)) found = true;
                    }
                    return .{ .result = truth(found), .value = val, .limit = limit };
                },
                .range => |rg| return rangeCondition(a, v, rg),
            }
        },
        .has => |p| {
            const is_present = present(r.map, p.name) != null;
            return .{ .result = truth(is_present), .value = .{ .bool = is_present }, .limit = .null };
        },
        .speed => |rg| return rangeCondition(a, present(r.map, "speed_ms"), rg),
        .altitude => |rg| return rangeCondition(a, present(r.map, "hae"), rg),
        .interval => |p| {
            const limit = json.Value{ .integer = p.min_ms };
            const kept = if (entities.get(r.key)) |s| s.kept_ms else null;
            const k = kept orelse return .{ .result = .no, .value = .null, .limit = limit };
            const value = @as(i128, r.time_ms) - k;
            return .{ .result = truth(value < p.min_ms), .value = intValue(value), .limit = limit };
        },
        .order => {
            const kept = if (entities.get(r.key)) |s| s.kept_ms else null;
            const value = json.Value{ .integer = r.time_ms };
            const k = kept orelse return .{ .result = .no, .value = value, .limit = .null };
            return .{ .result = truth(r.time_ms < k), .value = value, .limit = .{ .integer = k } };
        },
    }
}

// `env`, `affiliation`, `source`, `uid`: byte-for-byte membership in the `in` list.
fn listCondition(a: Allocator, value: ?[]const u8, items: []const []const u8) !Outcome {
    const limit = try record.stringList(a, items);
    const v = value orelse return .{ .result = .unknown, .value = .null, .limit = limit };
    var found = false;
    for (items) |item| {
        if (std.mem.eql(u8, item, v)) found = true;
    }
    return .{ .result = truth(found), .value = strValue(v), .limit = limit };
}

// `key` range, `speed`, `altitude`: inclusive bounds; unknown when absent or not a number.
fn rangeCondition(a: Allocator, value: ?json.Value, rg: fpack.Range) !Outcome {
    const limit = try rangeLimit(a, rg);
    const v = value orelse return .{ .result = .unknown, .value = .null, .limit = limit };
    const x = asNumber(v) orelse return .{ .result = .unknown, .value = v, .limit = limit };
    return .{ .result = truth(inRange(x, rg)), .value = v, .limit = limit };
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "conditions: present, unknown, lists, ranges and the reference" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const map = (try json.parseFromSliceLeaky(json.Value, a, "{\"type\":\"a-h-G\",\"speed_ms\":\"fast\",\"hae\":12,\"x\":true}", .{})).object;
        const r = Report{ .map = map, .key = "s/u", .source = "s", .uid = "u", .time_ms = 1000, .lat = 0, .lon = 0 };
        var ents = std.StringArrayHashMap(State).init(a);
        try std.testing.expectEqualStrings("G", environment("a-h-G").?);
        try std.testing.expectEqualStrings("h", affiliation("a-h-G").?);
        try std.testing.expect(affiliation("f-h-G") == null);
        try std.testing.expect(present(map, "speed_ms") == null);
        try std.testing.expect(keyEquals(.{ .bool = true }, .{ .text = "true", .number = null }));
        try std.testing.expect(keyEquals(.{ .integer = 2 }, .{ .text = "2.0", .number = 2 }));
        const env = try evaluate(a, &ents, .{ .env = .{ .in = &.{"G"} } }, r);
        try std.testing.expectEqual(Truth.yes, env.result);
        const sp = try evaluate(a, &ents, .{ .speed = .{ .min = 1, .max = null } }, r);
        try std.testing.expectEqual(Truth.unknown, sp.result);
        const alt = try evaluate(a, &ents, .{ .altitude = .{ .min = null, .max = 10 } }, r);
        try std.testing.expectEqual(Truth.no, alt.result);
        const near = try evaluate(a, &ents, .{ .near = .{ .reference = "t/v", .radius_m = 1, .max_age_ms = 10 } }, r);
        try std.testing.expectEqual(Truth.unknown, near.result);
        try ents.put("t/v", .{ .time_ms = 995, .lat = 0, .lon = 0, .course = null, .speed_ms = null, .stale_ms = null, .kept_ms = 900 });
        const near2 = try evaluate(a, &ents, .{ .near = .{ .reference = "t/v", .radius_m = 1, .max_age_ms = 10 } }, r);
        try std.testing.expectEqual(Truth.yes, near2.result);
        const ord = try evaluate(a, &ents, .order, r);
        try std.testing.expectEqual(Truth.no, ord.result);
        const iv = try evaluate(a, &ents, .{ .interval = .{ .min_ms = 10 } }, r);
        try std.testing.expectEqual(Truth.no, iv.result);
        const has = try evaluate(a, &ents, .{ .has = .{ .name = "hae" } }, r);
        try std.testing.expectEqual(Truth.yes, has.result);
        try std.testing.expectEqual(@as(i64, 5), intValue(5).integer);
        try std.testing.expect(intValue(@as(i128, std.math.maxInt(i64)) + 1) == .float);
    }
};
