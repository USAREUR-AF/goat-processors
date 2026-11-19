// Runs every filter load vector (spec/filter-load-vectors/) and every filter
// scenario vector (packs/filter-*/vectors/) with the comparison of
// spec/vector-format.md, printing the path of the first mismatch.
const std = @import("std");
const json = std.json;
const paths = @import("paths");
const fpack = @import("filter_pack.zig");
const filter = @import("filter.zig");
const compare = @import("compare.zig");
const vt = @import("vector_files.zig");

test {
    _ = @import("filter_geo.zig");
}

// Load vectors: parsing `pack_def` fails exactly when `expect_error` is true.
test "filter load vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var failed: usize = 0;
    const files = try vt.sortedJsonFiles(alloc, paths.filter_load_vectors_dir);
    for (files) |path| {
        const v = try vt.readJson(alloc, path);
        const expect_error = v.object.get("expect_error").?.bool;
        const got_error = if (fpack.parse(alloc, v.object.get("pack_def").?.string)) |_| false else |_| true;
        if (got_error != expect_error) {
            failed += 1;
            std.debug.print("FAIL filter load vector {s}: expect_error={} got_error={}\n", .{ path, expect_error, got_error });
        }
    }
    std.debug.print("filter load vectors: {d} run, {d} failed\n", .{ files.len, failed });
    try std.testing.expect(files.len > 0);
    try std.testing.expectEqual(@as(usize, 0), failed);
}

// One scenario vector: every step's events and trace, then the final snapshot.
fn runScenario(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const v = try vt.readJson(alloc, path);
    const name = v.object.get("name").?.string;
    const pack_dir = try std.fs.path.join(alloc, &.{ paths.packs_dir, v.object.get("pack").?.string });
    const pack = try filter.load_pack(alloc, pack_dir);
    const eng = try filter.Engine.create(std.testing.allocator, pack);
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

test "filter scenario vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var run: usize = 0;
    var failed: usize = 0;
    for (try vt.packDirs(alloc, "filter-")) |pn| {
        const vdir = try std.fs.path.join(alloc, &.{ paths.packs_dir, pn, "vectors" });
        for (try vt.sortedJsonFiles(alloc, vdir)) |path| {
            run += 1;
            if (try runScenario(alloc, path)) |mismatch| {
                failed += 1;
                std.debug.print("FAIL {s}: first mismatch at {s}\n", .{ path, mismatch });
            }
        }
    }
    std.debug.print("filter scenario vectors: {d} run, {d} failed\n", .{ run, failed });
    try std.testing.expect(run > 0);
    try std.testing.expectEqual(@as(usize, 0), failed);
}
