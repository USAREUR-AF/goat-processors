// spec/vector-format.md, as spec/quality.md "Vectors" applies it: runs every
// quality load vector (spec/quality-load-vectors/) and every scenario vector of
// the packs/quality-* packs, and prints the path of the first mismatch.
const std = @import("std");
const json = std.json;
const paths = @import("paths");
const qpack = @import("quality_pack.zig");
const quality = @import("quality.zig");
const compare = @import("compare.zig");
const files = @import("vector_files.zig");

// Load vectors: parsing `pack_def` fails exactly when `expect_error` is true.
test "quality load vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var failed: usize = 0;
    const paths_list = try files.sortedJsonFiles(alloc, paths.quality_load_vectors_dir);
    for (paths_list) |path| {
        const v = try files.readJson(alloc, path);
        const expect_error = v.object.get("expect_error").?.bool;
        const got_error = if (qpack.parse(alloc, v.object.get("pack_def").?.string)) |_| false else |_| true;
        if (got_error != expect_error) {
            failed += 1;
            std.debug.print("FAIL {s}: first mismatch at {s}.expect_error (want {}, got {})\n", .{ path, v.object.get("name").?.string, expect_error, got_error });
        }
    }
    std.debug.print("quality load vectors: {d} run, {d} failed\n", .{ paths_list.len, failed });
    try std.testing.expect(paths_list.len > 0);
    try std.testing.expectEqual(@as(usize, 0), failed);
}

// One scenario vector: every step's events and trace, then the final snapshot.
fn runScenario(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const v = try files.readJson(alloc, path);
    const name = v.object.get("name").?.string;
    const pack_dir = try std.fs.path.join(alloc, &.{ paths.packs_dir, v.object.get("pack").?.string });
    const pack = try quality.load_pack(alloc, pack_dir);
    const eng = try quality.Engine.create(std.testing.allocator, pack);
    defer eng.destroy();

    for (v.object.get("steps").?.array.items, 0..) |step, i| {
        const s = step.object;
        const res = if (s.get("ingest")) |report|
            try eng.ingest(report.object)
        else
            try eng.tick(s.get("tick").?.integer);
        const ev_path = try std.fmt.allocPrint(alloc, "{s}.steps[{d}].expect", .{ name, i });
        if (try compare.firstMismatch(alloc, ev_path, .{ .array = res.events }, s.get("expect").?)) |m| return m;
        const tr_path = try std.fmt.allocPrint(alloc, "{s}.steps[{d}].trace", .{ name, i });
        if (try compare.firstMismatch(alloc, tr_path, .{ .array = res.trace }, s.get("trace").?)) |m| return m;
    }
    const snap_path = try std.fmt.allocPrint(alloc, "{s}.snapshot", .{name});
    return compare.firstMismatch(alloc, snap_path, try eng.snapshot(), v.object.get("snapshot").?);
}

test "quality scenario vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var run: usize = 0;
    var failed: usize = 0;
    for (try files.sortedPackNames(alloc, paths.packs_dir, "quality-")) |pn| {
        const vdir = try std.fs.path.join(alloc, &.{ paths.packs_dir, pn, "vectors" });
        for (try files.sortedJsonFiles(alloc, vdir)) |path| {
            run += 1;
            if (try runScenario(alloc, path)) |mismatch| {
                failed += 1;
                std.debug.print("FAIL {s}: first mismatch at {s}\n", .{ path, mismatch });
            }
        }
    }
    std.debug.print("quality scenario vectors: {d} run, {d} failed\n", .{ run, failed });
    try std.testing.expect(run > 0);
    try std.testing.expectEqual(@as(usize, 0), failed);
}
