// spec/vector-format.md steps, as tools/perf/README.md "Runner contract" reads
// them: each step holds `ingest` (a report) or `tick` (an integer `now_ms`);
// any other key, in the file's object or in a step, is ignored.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const Step = union(enum) { ingest: json.ObjectMap, tick: i64 };

pub const Error = error{
    NotAnObject,
    NoSteps,
    StepsNotAList,
    StepNotAnObject,
    IngestNotAnObject,
    TickNotAnInteger,
    StepWithoutIngestOrTick,
} || Allocator.Error;

pub fn read(alloc: Allocator, root: json.Value) Error![]Step {
    if (root != .object) return error.NotAnObject;
    const list = root.object.get("steps") orelse return error.NoSteps;
    if (list != .array) return error.StepsNotAList;
    const out = try alloc.alloc(Step, list.array.items.len);
    for (list.array.items, out) |s, *o| o.* = try one(s);
    return out;
}

pub fn one(s: json.Value) Error!Step {
    if (s != .object) return error.StepNotAnObject;
    if (s.object.get("ingest")) |r| {
        if (r != .object) return error.IngestNotAnObject;
        return .{ .ingest = r.object };
    }
    if (s.object.get("tick")) |t| {
        if (t != .integer) return error.TickNotAnInteger;
        return .{ .tick = t.integer };
    }
    return error.StepWithoutIngestOrTick;
}

test "steps: ingest, tick, other keys ignored, errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a, "{\"name\":\"x\",\"steps\":[{\"ingest\":{\"uid\":\"1\"},\"expect\":[]},{\"tick\":5,\"trace\":[]}]}", .{});
    const s = try read(a, v);
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqual(@as(i64, 5), s[1].tick);
    const bad = try json.parseFromSliceLeaky(json.Value, a, "{\"steps\":[{\"tick\":1.5}]}", .{});
    try std.testing.expectError(error.TickNotAnInteger, read(a, bad));
    try std.testing.expectError(error.NoSteps, read(a, .{ .object = json.ObjectMap.init(a) }));
}
