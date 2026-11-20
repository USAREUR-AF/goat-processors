// The output of every operation: events and trace records as JSON values
// (spec/vector-format.md), and the builders every function writes them with.
// Objects keep their keys in the order given.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

// The result of one `ingest` or `tick`: its events, then its trace records.
pub const Result = struct {
    events: json.Array,
    trace: json.Array,

    pub fn init(a: Allocator) Result {
        return .{ .events = json.Array.init(a), .trace = json.Array.init(a) };
    }
};

// A Zig value as JSON: a json.Value as is, a bool, a float, an integer of any
// width, a string, an optional (null when absent), or a type with a
// `toJson()` declaration.
pub fn toValue(x: anytype) json.Value {
    const T = @TypeOf(x);
    if (T == json.Value) return x;
    if (T == bool) return .{ .bool = x };
    if (T == comptime_float) return .{ .float = x };
    if (T == comptime_int) return .{ .integer = x };
    switch (@typeInfo(T)) {
        .Float => return .{ .float = @floatCast(x) },
        .Int => return .{ .integer = @intCast(x) },
        .Pointer => |p| {
            if (p.size == .Slice and p.child == u8) return .{ .string = x };
            if (p.size == .One and @typeInfo(p.child) == .Array) return .{ .string = x };
        },
        .Optional => return if (x) |v| toValue(v) else .null,
        .Struct, .Union, .Enum => if (@hasDecl(T, "toJson")) return x.toJson(),
        else => {},
    }
    @compileError("unsupported value type " ++ @typeName(T));
}

// `fields` is a tuple of .{ name, value } pairs, kept in that order; the
// names are known at compile time and different from each other.
//
// The entries are appended with their hashes computed at compile time,
// instead of a `put` per field that hashes the name and looks for it; the
// hash index is built only above the hash map's eight-entry linear scan, as
// `put` would have built it.
pub fn object(a: Allocator, fields: anytype) Allocator.Error!json.Value {
    const Fields = @TypeOf(fields);
    comptime {
        const fs = @typeInfo(Fields).Struct.fields;
        for (fs, 0..) |x, i| for (fs[0..i]) |y| {
            if (std.mem.eql(u8, nameOf(x.type), nameOf(y.type))) @compileError("repeated field name " ++ nameOf(x.type));
        };
    }
    var m = json.ObjectMap.init(a);
    try m.unmanaged.entries.ensureTotalCapacity(a, fields.len);
    inline for (fields) |kv| {
        const name = comptime nameOf(@TypeOf(kv));
        const h = comptime (std.array_hash_map.StringContext{}).hash(name);
        m.unmanaged.entries.appendAssumeCapacity(.{ .key = name, .value = toValue(kv[1]), .hash = h });
    }
    if (fields.len > 8) try m.reIndex();
    return .{ .object = m };
}

// The name of a `.{ name, value }` pair: its first field, a string known at compile time.
fn nameOf(comptime Pair: type) []const u8 {
    const f = @typeInfo(Pair).Struct.fields[0];
    if (!f.is_comptime) @compileError("a field name must be known at compile time");
    const p: *const f.type = @ptrCast(@alignCast(f.default_value.?));
    return p.*;
}

// `items` is a tuple of values, kept in that order.
pub fn list(a: Allocator, items: anytype) Allocator.Error!json.Value {
    var arr = json.Array.init(a);
    try arr.ensureTotalCapacity(items.len);
    inline for (items) |x| arr.appendAssumeCapacity(toValue(x));
    return .{ .array = arr };
}

pub fn stringList(a: Allocator, items: []const []const u8) Allocator.Error!json.Value {
    var arr = json.Array.init(a);
    try arr.ensureTotalCapacity(items.len);
    for (items) |s| arr.appendAssumeCapacity(.{ .string = s });
    return .{ .array = arr };
}

pub fn floatList(a: Allocator, items: []const f64) Allocator.Error!json.Value {
    var arr = json.Array.init(a);
    try arr.ensureTotalCapacity(items.len);
    for (items) |x| arr.appendAssumeCapacity(.{ .float = x });
    return .{ .array = arr };
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "objects built by append look up like objects built by put, above and below eight fields" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var small = (try object(a, .{ .{ "a", 1 }, .{ "b", 2 } })).object;
        try std.testing.expectEqual(@as(i64, 2), small.get("b").?.integer);
        try small.put("c", .{ .integer = 3 });
        try small.put("a", .{ .integer = 9 });
        try std.testing.expectEqual(@as(i64, 9), small.get("a").?.integer);
        try std.testing.expectEqualStrings("a", small.keys()[0]);
        var big = (try object(a, .{ .{ "k1", 1 }, .{ "k2", 2 }, .{ "k3", 3 }, .{ "k4", 4 }, .{ "k5", 5 }, .{ "k6", 6 }, .{ "k7", 7 }, .{ "k8", 8 }, .{ "k9", 9 }, .{ "k10", 10 } })).object;
        for (big.keys(), 0..) |k, i| try std.testing.expectEqual(@as(i64, @intCast(i + 1)), big.get(k).?.integer);
        try big.put("k11", .{ .integer = 11 });
        try std.testing.expectEqual(@as(i64, 11), big.get("k11").?.integer);
        try std.testing.expect(big.get("k12") == null);
    }

    test "object keeps field order and converts values" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const none: ?f64 = null;
        const v = try object(a, .{ .{ "b", 1 }, .{ "a", 2.5 }, .{ "c", "x" }, .{ "d", none }, .{ "e", true }, .{ "f", @as(usize, 3) } });
        const keys = v.object.keys();
        try std.testing.expectEqualStrings("b", keys[0]);
        try std.testing.expectEqualStrings("a", keys[1]);
        try std.testing.expectEqual(@as(i64, 1), v.object.get("b").?.integer);
        try std.testing.expectEqual(@as(f64, 2.5), v.object.get("a").?.float);
        try std.testing.expectEqualStrings("x", v.object.get("c").?.string);
        try std.testing.expect(v.object.get("d").? == .null);
        try std.testing.expect(v.object.get("e").?.bool);
        try std.testing.expectEqual(@as(i64, 3), v.object.get("f").?.integer);
        const l = try list(a, .{ 1.0, "y" });
        try std.testing.expectEqual(@as(usize, 2), l.array.items.len);
    }
};
