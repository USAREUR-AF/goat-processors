// filter.md "Snapshot": `{"entities": {key: state}}`.
const std = @import("std");
const json = std.json;
const record = @import("../trace/record.zig");
const Engine = @import("../filter/engine.zig").Engine;

// Operation `snapshot()`: `{"entities": {key: state}}`.
pub fn snapshot(eng: *Engine) !json.Value {
    var entities = json.ObjectMap.init(eng.alloc());
    for (try eng.sortedKeys()) |key| {
        const s = eng.entities.get(key).?;
        try entities.put(key, try eng.object(.{
            .{ "time_ms", json.Value{ .integer = s.time_ms } },
            .{ "lat", json.Value{ .float = s.lat } },
            .{ "lon", json.Value{ .float = s.lon } },
            .{ "course", record.toValue(s.course) },
            .{ "speed_ms", record.toValue(s.speed_ms) },
            .{ "stale_ms", record.toValue(s.stale_ms) },
            .{ "kept_ms", record.toValue(s.kept_ms) },
        }));
    }
    return eng.object(.{.{ "entities", json.Value{ .object = entities } }});
}
