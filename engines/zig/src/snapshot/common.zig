// The parts of a snapshot every function writes the same way: the reference
// of the Frame and a filter (correlate.md "Snapshot": per axis
// `[p, v, pp, pv, vv]`).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const frame = @import("../model/frame.zig");
const kalman = @import("../model/kalman.zig");
const record = @import("../trace/record.zig");

// `[lat0, lon0]`, or null before the first accepted report.
pub fn refValue(a: Allocator, ref: ?frame.Frame) !json.Value {
    const r = ref orelse return .null;
    return record.floatList(a, &.{ r.lat0, r.lon0 });
}

// One axis: `[p, v, pp, pv, vv]`.
pub fn axisValue(a: Allocator, x: kalman.Axis) !json.Value {
    return record.floatList(a, &.{ x.p, x.v, x.pp, x.pv, x.vv });
}

// `{"east": [...], "north": [...]}`.
pub fn filterValue(a: Allocator, f: kalman.Filter) !json.Value {
    return record.object(a, .{ .{ "east", try axisValue(a, f.east) }, .{ "north", try axisValue(a, f.north) } });
}

// Keys in byte order, a copy.
pub fn sortedKeys(a: Allocator, keys: []const []const u8) ![][]const u8 {
    const out = try a.dupe([]const u8, keys);
    std.mem.sort([]const u8, out, {}, lessKey);
    return out;
}

pub fn lessKey(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

test "ref and filter values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try refValue(a, null)) == .null);
    const r = try refValue(a, .{ .lat0 = 1, .lon0 = 2 });
    try std.testing.expectEqual(@as(f64, 2), r.array.items[1].float);
    const ax = kalman.Axis{ .p = 1, .v = 2, .pp = 3, .pv = 4, .vv = 5 };
    const f = try filterValue(a, .{ .east = ax, .north = ax });
    try std.testing.expectEqual(@as(f64, 5), f.object.get("north").?.array.items[4].float);
}
