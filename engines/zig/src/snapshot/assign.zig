// correlate-assign.md "Snapshot": the snapshot of method `assign`.
const std = @import("std");
const json = std.json;
const engine_mod = @import("../correlate/engine.zig");
const assign = @import("../assign/assign.zig");
const membership = @import("../assign/membership.zig");
const common = @import("common.zig");
const snapshot_correlate = @import("correlate.zig");
const Engine = engine_mod.Engine;
const Membership = membership.Membership;
const History = assign.History;
const lessKey = engine_mod.lessKey;

fn systemsValue(eng: *Engine, m: Membership) !json.Value {
    var systems = json.ObjectMap.init(eng.alloc());
    for (m.systems.items) |s| try systems.put(try eng.groupName(s.id), try eng.stringList(s.members.items));
    return .{ .object = systems };
}

fn sortedList(eng: *Engine, keys: []const []const u8) !json.Value {
    const sorted = try eng.alloc().dupe([]const u8, keys);
    std.mem.sort([]const u8, sorted, {}, lessKey);
    return eng.stringList(sorted);
}

fn historyValue(eng: *Engine, hist: History) !json.Value {
    const a = eng.alloc();
    var records = json.Array.init(a);
    for (hist.records.items) |rec| {
        var choices = json.Array.init(a);
        for (rec.choices.items) |c| {
            var pair = json.Array.init(a);
            try pair.append(.{ .string = c.entity });
            try pair.append(.{ .string = if (c.chosen) |id| try eng.groupName(id) else "alone" });
            try choices.append(.{ .array = pair });
        }
        var events = json.Array.init(a);
        try events.appendSlice(rec.events.items);
        try records.append(try eng.object(.{
            .{ "cost", rec.cost },
            .{ "choices", json.Value{ .array = choices } },
            .{ "events", json.Value{ .array = events } },
            .{ "systems", try systemsValue(eng, rec.membership) },
            .{ "next_system", rec.membership.next_system },
        }));
    }
    return eng.object(.{ .{ "total", hist.total() }, .{ "records", json.Value{ .array = records } } });
}

pub fn snapshot(eng: *Engine) !json.Value {
    const a = eng.alloc();
    const st = assign.state(eng);
    const ref = try common.refValue(a, eng.ref);
    var entities = json.ObjectMap.init(a);
    for (try eng.sortedKeys()) |key| {
        const e = eng.entities.get(key).?;
        const system: ?[]const u8 = if (st.committed.systemOf(key)) |id| try eng.groupName(id) else null;
        var obj = try eng.object(.{ .{ "last_time_ms", e.last_time_ms }, .{ "system", system } });
        try snapshot_correlate.putFilter(eng, &obj.object, e);
        try entities.put(key, obj);
    }
    var out = try eng.object(.{
        .{ "ref", ref },
        .{ "entities", json.Value{ .object = entities } },
        .{ "systems", try systemsValue(eng, st.committed) },
        .{ "next_system", st.committed.next_system },
        .{ "reported", try sortedList(eng, st.reported.keys()) },
    });
    // correlate-assign.md 0.7: with `stale_rate`, `intervals`.
    try snapshot_correlate.putIntervals(eng, &out.object);
    // With `restart`: the restarted entities. With `bias`: the stored pairs, keys in order.
    if (eng.pack.restart != null) try out.object.put("restarted", try sortedList(eng, st.restarted.keys()));
    if (eng.pack.bias != null) {
        var pairs = json.ObjectMap.init(a);
        const keys = try a.dupe([]const u8, st.bias.pairs.keys());
        std.mem.sort([]const u8, keys, {}, lessKey);
        for (keys) |key| {
            const p = st.bias.pairs.get(key).?;
            var pair = try eng.object(.{
                .{ "east", p.east },
                .{ "weight_east", p.weight_east },
                .{ "north", p.north },
                .{ "weight_north", p.weight_north },
                .{ "var", p.variance },
                .{ "pairs", p.pairs },
            });
            // With `time_offset`: `time_offset_ms` (tau*1000) and `sums` ([S1, ..., S8]).
            if (eng.pack.time_offset != null) {
                try pair.object.put("time_offset_ms", .{ .float = p.tau * 1000.0 });
                var sums = json.Array.init(a);
                for (p.sums) |x| try sums.append(.{ .float = x });
                try pair.object.put("sums", .{ .array = sums });
            }
            try pairs.put(key, pair);
        }
        try out.object.put("bias", .{ .object = pairs });
    }
    // With a window: the retiring entities and the histories in rank order.
    if (eng.pack.window > 1) {
        try out.object.put("retiring", try sortedList(eng, st.retiring.keys()));
        var histories = json.Array.init(a);
        for (st.histories.items) |hist| try histories.append(try historyValue(eng, hist));
        try out.object.put("histories", .{ .array = histories });
    }
    return out;
}
