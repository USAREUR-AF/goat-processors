// quality.md "Snapshot": the reference, the last tick, per entity its source,
// `last`, `last_pos`, filter and window, and per rule its states by subject.
const std = @import("std");
const json = std.json;
const common = @import("common.zig");
const quality = @import("../quality/engine.zig");
const measures = @import("../quality/measures.zig");
const Engine = quality.Engine;
const Record = measures.Record;

fn recordValue(eng: *Engine, r: Record) !json.Value {
    return eng.object(.{
        .{ "wt", r.wt },
        .{ "time_ms", r.time_ms },
        .{ "order", r.order.name() },
        .{ "interval", r.interval },
        .{ "latency", r.latency },
        .{ "lateness", r.lateness },
        .{ "source_out_of_order", r.source_out_of_order },
        .{ "time_error", r.time_error },
        .{ "time_state", if (r.time_state) |ts| @tagName(ts) else null },
        .{ "nis", r.nis },
        .{ "speed_err", r.speed_err },
        .{ "ce", r.ce },
        .{ "vel", r.vel },
        .{ "hae", r.hae },
    });
}

// Spec "Snapshot", operation `snapshot()`.
pub fn snapshot(eng: *Engine) !json.Value {
    const a = eng.alloc();
    var entities = json.ObjectMap.init(a);
    for (try eng.sortedEntityKeys()) |key| {
        const e = eng.entities.get(key).?;
        var window = json.Array.init(a);
        for (e.window.items) |r| try window.append(try recordValue(eng, r));
        try entities.put(key, try eng.object(.{
            .{ "source", e.source },
            .{ "last_time_ms", e.last_time_ms },
            .{ "last_pos", try eng.list(.{ e.last_pos.east, e.last_pos.north }) },
            .{ "filter", try common.filterValue(a, e.filter) },
            .{ "window", json.Value{ .array = window } },
        }));
    }

    var rules = json.ObjectMap.init(a);
    for (eng.pack.rules, eng.rule_states) |rule, states| {
        var by_subject = json.ObjectMap.init(a);
        const subjects = try a.dupe([]const u8, states.keys());
        std.mem.sort([]const u8, subjects, {}, common.lessKey);
        for (subjects) |s| {
            const st = states.get(s).?;
            try by_subject.put(s, try eng.object(.{ .{ "count", st.count }, .{ "active", st.active } }));
        }
        try rules.put(rule.name, .{ .object = by_subject });
    }

    const ref = try common.refValue(a, eng.ref);
    return eng.object(.{
        .{ "ref", ref },
        .{ "last_tick", eng.last_tick },
        .{ "entities", json.Value{ .object = entities } },
        .{ "rules", json.Value{ .object = rules } },
    });
}
