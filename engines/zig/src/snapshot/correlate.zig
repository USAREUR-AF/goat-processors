// correlate.md "Snapshot": the entity's filter (with `models`, `mode` and
// `time`), and the snapshot of method `confirm` (moved here unchanged).
const std = @import("std");
const json = std.json;
const engine_mod = @import("../correlate/engine.zig");
const Entity = @import("../correlate/entity.zig").Entity;
const common = @import("common.zig");
const confirm_method = @import("../correlate/confirm.zig");
const record = @import("../trace/record.zig");
const Engine = engine_mod.Engine;

// Spec "Snapshot": `filter`, plus `models` and `mode` with the `maneuver`
// directive, plus `time` (correlate.md 0.8).
pub fn putFilter(eng: *Engine, obj: *json.ObjectMap, e: Entity) !void {
    const a = eng.alloc();
    try obj.put("filter", try common.filterValue(a, e.filter));
    if (e.imm) |st| {
        try obj.put("models", try record.object(a, .{
            .{ "quiet", try common.filterValue(a, st.models[0]) },
            .{ "maneuver", try common.filterValue(a, st.models[1]) },
        }));
        try obj.put("mode", try record.floatList(a, &st.mu));
    }
    // correlate.md 0.8 "Snapshot": `time`, the timing variance, when the
    // entity's last report had a time error above 0.
    if (e.time_error_ms > 0) {
        try obj.put("time", try record.object(a, .{ .{ "var_east", e.time_var_east }, .{ "var_north", e.time_var_north } }));
    }
}

// correlate.md 1.0 "Snapshot", with `stale_rate`: `intervals`, each source
// that has at least one interval to its list, oldest first. Both methods.
pub fn putIntervals(eng: *Engine, obj: *json.ObjectMap) !void {
    if (eng.pack.stale_rate == null) return;
    const a = eng.alloc();
    const sources = try common.sortedKeys(a, eng.intervals.keys());
    var out = json.ObjectMap.init(a);
    for (sources) |src| {
        const list = eng.intervals.get(src).?;
        var arr = json.Array.init(a);
        for (list.items) |x| try arr.append(.{ .integer = x });
        try out.put(src, .{ .array = arr });
    }
    try obj.put("intervals", .{ .object = out });
}

// Spec operation `snapshot()`, method confirm.
pub fn confirm(eng: *Engine) !json.Value {
    const ref = try common.refValue(eng.alloc(), eng.ref);

    var entities = json.ObjectMap.init(eng.alloc());
    for (try eng.sortedKeys()) |key| {
        const e = eng.entities.get(key).?;
        const group: ?[]const u8 = if (e.group) |gid| try eng.groupName(gid) else null;
        var obj = try eng.object(.{
            .{ "last_time_ms", e.last_time_ms },
            .{ "group", group },
            .{ "hold_failures", e.hold_failures },
        });
        try putFilter(eng, &obj.object, e);
        try entities.put(key, obj);
    }

    var groups = json.ObjectMap.init(eng.alloc());
    for (confirm_method.state(eng).groups.items) |g| try groups.put(try eng.groupName(g.id), try eng.stringList(g.members.items));

    var counts = json.ObjectMap.init(eng.alloc());
    for (confirm_method.state(eng).counts.items) |pc| {
        try counts.put(try std.fmt.allocPrint(eng.alloc(), "{s}|{s}", .{ pc.a, pc.b }), .{ .integer = pc.count });
    }

    var out = try eng.object(.{
        .{ "ref", ref },
        .{ "entities", json.Value{ .object = entities } },
        .{ "groups", json.Value{ .object = groups } },
        .{ "counts", json.Value{ .object = counts } },
        .{ "next_group", confirm_method.state(eng).next_group },
    });
    // correlate.md 1.0: with `sprt`, `llr`, each pair key that has an `L`.
    if (eng.pack.sprt != null) {
        var llr = json.ObjectMap.init(eng.alloc());
        for (confirm_method.state(eng).llr.items) |pl| {
            try llr.put(try std.fmt.allocPrint(eng.alloc(), "{s}|{s}", .{ pl.a, pl.b }), .{ .float = pl.l });
        }
        try out.object.put("llr", .{ .object = llr });
    }
    try putIntervals(eng, &out.object);
    return out;
}
