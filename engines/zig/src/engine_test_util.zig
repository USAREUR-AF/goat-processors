// Helpers for the engines' unit tests: run steps written as JSON text through
// a function module and collect its output.
const std = @import("std");
const json = std.json;
const steps_mod = @import("io/steps.zig");

pub const Out = struct { events: []json.Value, trace: []json.Value, snapshot: json.Value };

// `pack_def` parsed by M's parser, then every step of `steps` (a JSON array of steps).
pub fn run(comptime M: type, a: std.mem.Allocator, pack: M.Pack, steps_text: []const u8) !Out {
    const v = try json.parseFromSliceLeaky(json.Value, a, steps_text, .{});
    const eng = try M.Engine.create(a, pack);
    var events = std.ArrayList(json.Value).init(a);
    var trace = std.ArrayList(json.Value).init(a);
    for (v.array.items) |s| {
        const res = switch (try steps_mod.one(s)) {
            .ingest => |r| try eng.ingest(r),
            .tick => |t| try eng.tick(t),
        };
        try events.append(.{ .array = res.events });
        try trace.append(.{ .array = res.trace });
    }
    return .{ .events = events.items, .trace = trace.items, .snapshot = try eng.snapshot() };
}

// The `ev` of event `i` of step `s`.
pub fn ev(o: Out, s: usize, i: usize) []const u8 {
    return o.events[s].array.items[i].object.get("ev").?.string;
}

// True when step `s` gave an event `name`.
pub fn has(o: Out, s: usize, name: []const u8) bool {
    for (o.events[s].array.items) |e| {
        if (std.mem.eql(u8, e.object.get("ev").?.string, name)) return true;
    }
    return false;
}
