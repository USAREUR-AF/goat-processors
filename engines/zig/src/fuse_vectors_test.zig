// spec/vector-format.md: every fuse load vector and every scenario vector of
// the packs/fuse-* packs, through the entry point of api.zig.
const std = @import("std");
const paths = @import("paths");
const api = @import("api.zig");
const vectors = @import("io/vectors.zig");
const pack = @import("fuse/pack.zig");

test "fuse load vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try vectors.expectPassed(try vectors.loadVectors(arena.allocator(), paths.fuse_load_vectors_dir, "fuse", pack.parse));
}

test "fuse scenario vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try vectors.expectPassed(try vectors.scenarioVectors(api.Module(.fuse), arena.allocator(), paths.packs_dir, "fuse-"));
}
