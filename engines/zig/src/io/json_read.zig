// Reading files and JSON. A file of any size the harness writes is read whole
// (the perf harness writes steps and vector files of about 150 MB).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

// The whole file at `path`, any size.
pub fn readFile(a: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, std.math.maxInt(usize));
}

// A JSON text as a json.Value; strings are copied into `a`.
pub fn parse(a: Allocator, text: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, a, text, .{});
}

pub fn readJson(a: Allocator, path: []const u8) !json.Value {
    return parse(a, try readFile(a, path));
}

// `<dir>/pack.def`, the text every function's `load_pack(dir)` reads.
pub fn readPackDef(a: Allocator, dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ dir, "pack.def" });
    return readFile(a, path);
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "reads a file larger than 16 MiB" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const n: usize = (1 << 24) + 10;
        {
            const f = try tmp.dir.createFile("big.json", .{});
            defer f.close();
            var bw = std.io.bufferedWriter(f.writer());
            try bw.writer().writeByte('"');
            try bw.writer().writeByteNTimes('x', n - 2);
            try bw.writer().writeByte('"');
            try bw.flush();
        }
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const path = try tmp.dir.realpathAlloc(arena.allocator(), "big.json");
        const v = try readJson(arena.allocator(), path);
        try std.testing.expectEqual(n - 2, v.string.len);
    }
};
