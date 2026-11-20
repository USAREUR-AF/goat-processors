// Replaying steps through a function module and writing all of its output as
// the runner's events file does: one line per step (events and trace), then
// the snapshot. Used by the property and fuzz tests to compare output bytes.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const steps_mod = @import("steps.zig");
const json_write = @import("json_write.zig");

pub fn bytes(comptime M: type, a: Allocator, pack: M.Pack, steps: []const steps_mod.Step) ![]u8 {
    const eng = try M.Engine.create(a, pack);
    defer eng.destroy();
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    for (steps, 0..) |s, i| {
        const res = switch (s) {
            .ingest => |r| try eng.ingest(r),
            .tick => |t| try eng.tick(t),
        };
        try w.print("{{\"step\":{d},\"events\":", .{i});
        try json_write.writeValue(w, .{ .array = res.events });
        try w.writeAll(",\"trace\":");
        try json_write.writeValue(w, .{ .array = res.trace });
        try w.writeAll("}\n");
    }
    try w.writeAll("{\"snapshot\":");
    try json_write.writeValue(w, try eng.snapshot());
    try w.writeAll("}\n");
    return out.items;
}

pub const Output = struct { events: []json.Value, trace: []json.Value, snapshot: json.Value };

// The output as values, for a structural comparison. The engine is not
// destroyed: its arena (on `a`) holds the values.
pub fn values(comptime M: type, a: Allocator, pack: M.Pack, steps: []const steps_mod.Step) !Output {
    const eng = try M.Engine.create(a, pack);
    const events = try a.alloc(json.Value, steps.len);
    const trace = try a.alloc(json.Value, steps.len);
    for (steps, events, trace) |s, *e, *t| {
        const res = switch (s) {
            .ingest => |r| try eng.ingest(r),
            .tick => |x| try eng.tick(x),
        };
        e.* = .{ .array = res.events };
        t.* = .{ .array = res.trace };
    }
    return .{ .events = events, .trace = trace, .snapshot = try eng.snapshot() };
}
