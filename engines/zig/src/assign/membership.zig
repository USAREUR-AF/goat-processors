// correlate-assign.md "Memberships": the system tracks, and the `leave`,
// `end`, `join` and `start` of an entity.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Engine = @import("../correlate/engine.zig").Engine;

pub const System = struct { id: u64, members: std.ArrayList([]const u8) };

// One picture of the system tracks: the tracks in creation order, each with its
// members in key order, and the counter that names the next one.
pub const Membership = struct {
    systems: std.ArrayList(System),
    next_system: u64,

    pub fn init(alloc: Allocator) Membership {
        return .{ .systems = std.ArrayList(System).init(alloc), .next_system = 1 };
    }

    pub fn clone(self: Membership, alloc: Allocator) !Membership {
        var out = Membership{ .systems = std.ArrayList(System).init(alloc), .next_system = self.next_system };
        for (self.systems.items) |s| {
            var list = std.ArrayList([]const u8).init(alloc);
            try list.appendSlice(s.members.items);
            try out.systems.append(.{ .id = s.id, .members = list });
        }
        return out;
    }

    pub fn systemOf(self: Membership, key: []const u8) ?u64 {
        for (self.systems.items) |s| {
            for (s.members.items) |m| if (std.mem.eql(u8, m, key)) return s.id;
        }
        return null;
    }

    pub fn index(self: Membership, id: u64) usize {
        for (self.systems.items, 0..) |s, i| if (s.id == id) return i;
        unreachable;
    }

    pub fn members(self: Membership, id: u64) []const []const u8 {
        return self.systems.items[self.index(id)].members.items;
    }
};

// A leaves its system track (`leave`), which ends when left empty (`end`).
pub fn leave(eng: *Engine, m: *Membership, events: *std.ArrayList(json.Value), key: []const u8, reason: []const u8) !void {
    const id = m.systemOf(key).?;
    const i = m.index(id);
    const list = &m.systems.items[i].members;
    for (list.items, 0..) |x, j| {
        if (std.mem.eql(u8, x, key)) {
            _ = list.orderedRemove(j);
            break;
        }
    }
    const name = try eng.groupName(id);
    try events.append(try eng.object(.{ .{ "ev", "leave" }, .{ "system", name }, .{ "entity", key }, .{ "reason", reason } }));
    if (list.items.len == 0) {
        _ = m.systems.orderedRemove(i);
        try events.append(try eng.object(.{ .{ "ev", "end" }, .{ "system", name } }));
    }
}

pub fn join(eng: *Engine, m: *Membership, events: *std.ArrayList(json.Value), id: u64, key: []const u8) !void {
    try Engine.insertSorted(&m.systems.items[m.index(id)].members, key);
    try events.append(try eng.object(.{ .{ "ev", "join" }, .{ "system", try eng.groupName(id) }, .{ "entity", key } }));
}

pub fn start(eng: *Engine, m: *Membership, events: *std.ArrayList(json.Value), key: []const u8) !void {
    const id = m.next_system;
    m.next_system += 1;
    var list = std.ArrayList([]const u8).init(eng.alloc());
    try list.append(key);
    try m.systems.append(.{ .id = id, .members = list });
    try events.append(try eng.object(.{ .{ "ev", "start" }, .{ "system", try eng.groupName(id) }, .{ "entity", key } }));
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "systemOf, index and clone" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var m = Membership.init(a);
        var l = std.ArrayList([]const u8).init(a);
        try l.append("s/1");
        try m.systems.append(.{ .id = 3, .members = l });
        try std.testing.expectEqual(@as(?u64, 3), m.systemOf("s/1"));
        try std.testing.expect(m.systemOf("s/2") == null);
        const c = try m.clone(a);
        try m.systems.items[0].members.append("s/2");
        try std.testing.expectEqual(@as(usize, 1), c.members(3).len);
        try std.testing.expectEqual(@as(usize, 0), c.index(3));
    }
};
