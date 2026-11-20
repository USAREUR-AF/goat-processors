// Writing JSON values: objects in key order as stored, floats in Zig's
// shortest round-trip form, NaN and infinities as Python's json module writes them.
const std = @import("std");
const json = std.json;

pub fn writeValue(w: anytype, v: json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) {
                try w.writeAll("NaN");
            } else if (std.math.isInf(f)) {
                try w.writeAll(if (f > 0) "Infinity" else "-Infinity");
            } else try w.print("{}", .{f});
        },
        .number_string => |s| try w.writeAll(s),
        .string => |s| try json.encodeJsonString(s, .{}, w),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(w, x);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                try json.encodeJsonString(e.key_ptr.*, .{}, w);
                try w.writeByte(':');
                try writeValue(w, e.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "writes every kind" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const v = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"a\":[1,2.5,null,true,\"x\\\"\"],\"b\":{}}", .{});
        var buf = std.ArrayList(u8).init(arena.allocator());
        try writeValue(buf.writer(), v);
        try std.testing.expectEqualStrings("{\"a\":[1,2.5e0,null,true,\"x\\\"\"],\"b\":{}}", buf.items);
        buf.clearRetainingCapacity();
        try writeValue(buf.writer(), .{ .float = std.math.nan(f64) });
        try std.testing.expectEqualStrings("NaN", buf.items);
    }
};
