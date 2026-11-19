// spec/vector-format.md "What the engine checks": structural equality.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

fn asNumber(v: json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// abs(got - want) <= 1e-6 * max(1, abs(want)); an integer and a float compare as numbers.
fn numbersEqual(got: f64, want: f64) bool {
    return @abs(got - want) <= 1e-6 * @max(1.0, @abs(want));
}

// Returns the path of the first mismatch, or null when `got` equals `want`.
pub fn firstMismatch(alloc: Allocator, path: []const u8, got: json.Value, want: json.Value) Allocator.Error!?[]const u8 {
    const mismatch: ?[]const u8 = path;
    if (asNumber(want)) |w| {
        const g = asNumber(got) orelse return mismatch;
        return if (numbersEqual(g, w)) null else mismatch;
    }
    switch (want) {
        .null => return if (got == .null) null else mismatch,
        .bool => |w| return if (got == .bool and got.bool == w) null else mismatch,
        .string => |w| return if (got == .string and std.mem.eql(u8, got.string, w)) null else mismatch,
        .array => |w| {
            if (got != .array) return mismatch;
            if (got.array.items.len != w.items.len) return try std.fmt.allocPrint(alloc, "{s} (length {d}, want {d})", .{ path, got.array.items.len, w.items.len });
            for (got.array.items, w.items, 0..) |g, x, i| {
                const sub = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ path, i });
                if (try firstMismatch(alloc, sub, g, x)) |m| return m;
            }
            return null;
        },
        .object => |w| {
            if (got != .object) return mismatch;
            var it = w.iterator();
            while (it.next()) |e| {
                const sub = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, e.key_ptr.* });
                const g = got.object.get(e.key_ptr.*) orelse return try std.fmt.allocPrint(alloc, "{s} (absent)", .{sub});
                if (try firstMismatch(alloc, sub, g, e.value_ptr.*)) |m| return m;
            }
            var git = got.object.iterator();
            while (git.next()) |e| {
                if (w.get(e.key_ptr.*) == null) return try std.fmt.allocPrint(alloc, "{s}.{s} (unexpected)", .{ path, e.key_ptr.* });
            }
            return null;
        },
        .integer, .float, .number_string => unreachable,
    }
}

test "numbers compare within tolerance, null differs from absent" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const p = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"x\":1,\"y\":null}", .{});
    const q = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"x\":1.0000000001,\"y\":null}", .{});
    const r = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"x\":1}", .{});
    try std.testing.expect((try firstMismatch(arena.allocator(), "$", p, q)) == null);
    try std.testing.expect((try firstMismatch(arena.allocator(), "$", r, p)) != null);
}
