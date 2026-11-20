// spec/vector-format.md: finding vector files, shared by the vector tests.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// The `*.json` files of a directory, as paths, in name order.
pub fn sortedJsonFiles(alloc: Allocator, dir_path: []const u8) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var names = std.ArrayList([]const u8).init(alloc);
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".json")) {
            try names.append(try std.fs.path.join(alloc, &.{ dir_path, e.name }));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessName);
    return names.items;
}

// The pack directory names under `packs_dir` that start with `prefix`, in name order.
pub fn sortedPackNames(alloc: Allocator, packs_dir: []const u8, prefix: []const u8) ![][]const u8 {
    var packs = try std.fs.cwd().openDir(packs_dir, .{ .iterate = true });
    defer packs.close();
    var names = std.ArrayList([]const u8).init(alloc);
    var it = packs.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory and std.mem.startsWith(u8, e.name, prefix)) try names.append(try alloc.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessName);
    return names.items;
}
