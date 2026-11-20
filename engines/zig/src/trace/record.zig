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

// `fields` is a tuple of .{ name, value } pairs, kept in that order.
pub fn object(a: Allocator, fields: anytype) Allocator.Error!json.Value {
    var m = json.ObjectMap.init(a);
    try m.ensureTotalCapacity(fields.len);
    inline for (fields) |kv| m.putAssumeCapacity(kv[0], toValue(kv[1]));
    return .{ .object = m };
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
