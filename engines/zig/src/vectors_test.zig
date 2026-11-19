// spec/vector-format.md: runs every load vector and every scenario vector.
const std = @import("std");
const json = std.json;
const paths = @import("paths");
const pack_mod = @import("pack.zig");
const engine_mod = @import("engine.zig");
const compare = @import("compare.zig");

test {
    _ = compare;
    _ = @import("hungarian.zig");
}

fn sortedJsonFiles(alloc: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
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

fn readJson(alloc: std.mem.Allocator, path: []const u8) !json.Value {
    const text = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 24);
    return json.parseFromSliceLeaky(json.Value, alloc, text, .{});
}

// Load vectors: parsing `pack_def` fails exactly when `expect_error` is true.
test "load vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var failed: usize = 0;
    const files = try sortedJsonFiles(alloc, paths.load_vectors_dir);
    for (files) |path| {
        const v = try readJson(alloc, path);
        const expect_error = v.object.get("expect_error").?.bool;
        const got_error = if (pack_mod.parse(alloc, v.object.get("pack_def").?.string)) |_| false else |_| true;
        if (got_error != expect_error) {
            failed += 1;
            std.debug.print("FAIL load vector {s}: expect_error={} got_error={}\n", .{ path, expect_error, got_error });
        }
    }
    std.debug.print("load vectors: {d} run, {d} failed\n", .{ files.len, failed });
    try std.testing.expect(files.len > 0);
    try std.testing.expectEqual(@as(usize, 0), failed);
}

// One scenario vector: every step's events and trace, then the final snapshot.
fn runScenario(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const v = try readJson(alloc, path);
    const name = v.object.get("name").?.string;
    const pack_dir = try std.fs.path.join(alloc, &.{ paths.packs_dir, v.object.get("pack").?.string });
    const pack = try engine_mod.load_pack(alloc, pack_dir);
    const eng = try engine_mod.Engine.create(std.testing.allocator, pack);
    defer eng.destroy();

    for (v.object.get("steps").?.array.items, 0..) |step, i| {
        const s = step.object;
        const res = if (s.get("ingest")) |report|
            try eng.ingest(report.object)
        else
            try eng.tick(s.get("tick").?.integer);
        const at = try std.fmt.allocPrint(alloc, "{s}.steps[{d}]", .{ name, i });
        const ev_path = try std.fmt.allocPrint(alloc, "{s}.expect", .{at});
        if (try compare.firstMismatch(alloc, ev_path, .{ .array = res.events }, s.get("expect").?)) |m| return m;
        const tr_path = try std.fmt.allocPrint(alloc, "{s}.trace", .{at});
        if (try compare.firstMismatch(alloc, tr_path, .{ .array = res.trace }, s.get("trace").?)) |m| return m;
    }
    const snap_path = try std.fmt.allocPrint(alloc, "{s}.snapshot", .{name});
    return compare.firstMismatch(alloc, snap_path, try eng.snapshot(), v.object.get("snapshot").?);
}

test "scenario vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var run: usize = 0;
    var failed: usize = 0;

    var packs = try std.fs.cwd().openDir(paths.packs_dir, .{ .iterate = true });
    defer packs.close();
    var pack_names = std.ArrayList([]const u8).init(alloc);
    var it = packs.iterate();
    while (try it.next()) |e| if (e.kind == .directory and std.mem.startsWith(u8, e.name, "correlate-")) try pack_names.append(try alloc.dupe(u8, e.name));
    std.mem.sort([]const u8, pack_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (pack_names.items) |pn| {
        const vdir = try std.fs.path.join(alloc, &.{ paths.packs_dir, pn, "vectors" });
        for (try sortedJsonFiles(alloc, vdir)) |path| {
            run += 1;
            if (try runScenario(alloc, path)) |mismatch| {
                failed += 1;
                std.debug.print("FAIL {s}: first mismatch at {s}\n", .{ path, mismatch });
            }
        }
    }
    std.debug.print("scenario vectors: {d} run, {d} failed\n", .{ run, failed });
    try std.testing.expect(run > 0);
    try std.testing.expectEqual(@as(usize, 0), failed);
}
