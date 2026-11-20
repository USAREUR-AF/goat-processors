// spec/vector-format.md: running the load vectors and the scenario vectors of
// one function through its entry point (api.zig), with the structural
// comparison of compare.zig. Shared by the four vector test roots.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const compare = @import("compare.zig");
const files = @import("vector_files.zig");
const json_read = @import("json_read.zig");

pub const Counts = struct { run: usize = 0, failed: usize = 0 };

// Load vectors: parsing `pack_def` fails exactly when `expect_error` is true.
// `parse` is the function's pack.def parser.
pub fn loadVectors(alloc: Allocator, dir: []const u8, comptime label: []const u8, parse: anytype) !Counts {
    var c = Counts{};
    for (try files.sortedJsonFiles(alloc, dir)) |path| {
        c.run += 1;
        const v = try json_read.readJson(alloc, path);
        const expect_error = v.object.get("expect_error").?.bool;
        const got_error = if (parse(alloc, v.object.get("pack_def").?.string)) |_| false else |_| true;
        if (got_error != expect_error) {
            c.failed += 1;
            std.debug.print("FAIL " ++ label ++ " load vector {s}: expect_error={} got_error={}\n", .{ path, expect_error, got_error });
        }
    }
    std.debug.print(label ++ " load vectors: {d} run, {d} failed\n", .{ c.run, c.failed });
    return c;
}

// One scenario vector of function module M: every step's events and trace,
// then the final snapshot. Returns the path of the first mismatch, or null.
pub fn runScenario(comptime M: type, alloc: Allocator, packs_dir: []const u8, path: []const u8) !?[]const u8 {
    const v = try json_read.readJson(alloc, path);
    const name = v.object.get("name").?.string;
    const pack_dir = try std.fs.path.join(alloc, &.{ packs_dir, v.object.get("pack").?.string });
    const pack = try M.load_pack(alloc, pack_dir);
    const eng = try M.Engine.create(std.testing.allocator, pack);
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

// Every scenario vector of the packs under `packs_dir` whose names start with `prefix`.
pub fn scenarioVectors(comptime M: type, alloc: Allocator, packs_dir: []const u8, comptime prefix: []const u8) !Counts {
    var c = Counts{};
    for (try files.sortedPackNames(alloc, packs_dir, prefix)) |pn| {
        const vdir = try std.fs.path.join(alloc, &.{ packs_dir, pn, "vectors" });
        for (try files.sortedJsonFiles(alloc, vdir)) |path| {
            c.run += 1;
            // Each vector in its own arena, so a large vector's input is freed after it.
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            if (try runScenario(M, arena.allocator(), packs_dir, path)) |mismatch| {
                c.failed += 1;
                std.debug.print("FAIL {s}: first mismatch at {s}\n", .{ path, mismatch });
            }
        }
    }
    const label = prefix[0 .. prefix.len - 1];
    std.debug.print("{s} scenario vectors: {d} run, {d} failed\n", .{ label, c.run, c.failed });
    return c;
}

pub fn expectPassed(c: Counts) !void {
    try std.testing.expect(c.run > 0);
    try std.testing.expectEqual(@as(usize, 0), c.failed);
}
