// fuse.md "Snapshot": the reference and, per entity, `last_time_ms`, `group`,
// `filter` and the last normalized `report`.
const std = @import("std");
const json = std.json;
const record = @import("../trace/record.zig");
const common = @import("common.zig");
const Engine = @import("../fuse/engine.zig").Engine;
const object = record.object;

pub fn snapshot(eng: *Engine) !json.Value {
    const a = eng.alloc();
    var ents = json.ObjectMap.init(a);
    for (try eng.sortedKeys()) |k| {
        const e = eng.entities.get(k).?;
        try ents.put(k, try object(a, .{
            .{ "last_time_ms", e.last_time_ms },
            .{ "group", e.group },
            .{ "filter", try common.filterValue(a, e.filter) },
            .{ "report", json.Value{ .object = e.report } },
        }));
    }
    const ref = try common.refValue(a, eng.ref);
    return object(a, .{ .{ "ref", ref }, .{ "entities", json.Value{ .object = ents } } });
}
