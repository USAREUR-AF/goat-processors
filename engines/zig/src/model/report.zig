// correlate.md "Reports": the typed key readers every function uses (filter,
// fuse and quality cite correlate.md's Reports), the required keys, and the
// report's own time quality (correlate.md 0.8 "Time quality", step 1).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const params = @import("params.zig");

// "Reports": the required keys, in the order of the table.
pub const Required = struct {
    source: []const u8,
    uid: []const u8,
    time_ms: i64,
    lat: f64,
    lon: f64,
};

// The required keys of a report, or the name of the first one missing or of
// the wrong type, in the order of the table.
pub const Checked = union(enum) { ok: Required, missing: []const u8 };

pub fn required(m: json.ObjectMap) Checked {
    const source = stringOf(m, "track.source_id") orelse return .{ .missing = "track.source_id" };
    const uid = stringOf(m, "uid") orelse return .{ .missing = "uid" };
    const time_ms = integerOf(m, "time_ms") orelse return .{ .missing = "time_ms" };
    const lat = numberOf(m, "lat") orelse return .{ .missing = "lat" };
    const lon = numberOf(m, "lon") orelse return .{ .missing = "lon" };
    return .{ .ok = .{ .source = source, .uid = uid, .time_ms = time_ms, .lat = lat, .lon = lon } };
}

// A JSON number as binary64 (an integer, a float, or a number string).
pub fn asNumber(v: json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn isNumber(v: json.Value) bool {
    return v == .integer or v == .float or v == .number_string;
}

// A deep copy of a JSON value into `a`, keys included.
pub fn cloneValue(a: Allocator, v: json.Value) Allocator.Error!json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = json.Array.init(a);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try cloneValue(a, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out = json.ObjectMap.init(a);
            try out.ensureTotalCapacity(obj.count());
            var it = obj.iterator();
            while (it.next()) |e| out.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}

pub fn numberOf(m: json.ObjectMap, key: []const u8) ?f64 {
    return asNumber(m.get(key) orelse return null);
}

// Spec 0.3 "Reports": a `ce` of 0 or below is treated as absent.
pub fn ceOf(m: json.ObjectMap) ?f64 {
    const c = numberOf(m, "ce") orelse return null;
    return if (c > 0) c else null;
}

// correlate.md 0.8 "Reports", "Time quality": the time error and time state of
// a report, found per key: the report's own key when present, otherwise the
// pack's `time_default` for its source, otherwise 0 and `coherent`.
pub const TimeQuality = struct { error_ms: f64, state: params.TimeState };

pub fn timeQualityOf(m: json.ObjectMap, source: []const u8, defaults: []const params.TimeDefault) TimeQuality {
    const default = params.timeDefaultOf(defaults, source);
    const error_ms = reportTimeErrorOf(m) orelse if (default) |d| d.error_ms else null;
    const state = reportTimeStateOf(m) orelse if (default) |d| d.state else null;
    return .{ .error_ms = error_ms orelse 0, .state = state orelse .coherent };
}

// correlate.md 0.8 "Time quality", step 1, shared with quality.md 0.2 "Time
// quality": the report's own `time_error_ms`, a finite number 0 or above;
// anything else is absent.
pub fn reportTimeErrorOf(m: json.ObjectMap) ?f64 {
    const x = numberOf(m, "time_error_ms") orelse return null;
    return if (std.math.isFinite(x) and x >= 0) x else null;
}

// The report's own `time_state`: one of the three strings, byte for byte;
// anything else is absent.
pub fn reportTimeStateOf(m: json.ObjectMap) ?params.TimeState {
    const t = stringOf(m, "time_state") orelse return null;
    return std.meta.stringToEnum(params.TimeState, t);
}

pub fn integerOf(m: json.ObjectMap, key: []const u8) ?i64 {
    const v = m.get(key) orelse return null;
    return switch (v) {
        // Spec 0.3 "Reports": an integer is a JSON number written without a fraction or
        // an exponent; std.json yields `.float` for `1000.0` and `1e3`, so those are the wrong type.
        .integer => |i| i,
        else => null,
    };
}

pub fn stringOf(m: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = m.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
