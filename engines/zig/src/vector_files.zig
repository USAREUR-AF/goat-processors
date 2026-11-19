// spec/vector-format.md: finding and reading vector files, shared by the
// correlate and filter vector tests.
const std = @import("std");
const json = std.json;
const paths = @import("paths");

pub fn sortedJsonFiles(alloc: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var names = std.ArrayList([]const u8).init(alloc);
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".json")) {
            try names.append(try std.fs.path.join(alloc, &.{ dir_path, e.name }));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return names.items;
}

pub fn readJson(alloc: std.mem.Allocator, path: []const u8) !json.Value {
    const text = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 24);
    return json.parseFromSliceLeaky(json.Value, alloc, text, .{});
}

// The pack directories under packs_dir whose names start with `prefix`, in byte order.
pub fn packDirs(alloc: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var packs = try std.fs.cwd().openDir(paths.packs_dir, .{ .iterate = true });
    defer packs.close();
    var names = std.ArrayList([]const u8).init(alloc);
    var it = packs.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory and std.mem.startsWith(u8, e.name, prefix)) try names.append(try alloc.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return names.items;
}
