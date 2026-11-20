// spec/vector-format.md: every quality load vector and every scenario vector of
// the packs/quality-* packs, through the entry point of api.zig.
const std = @import("std");
const paths = @import("paths");
const api = @import("api.zig");
const vectors = @import("io/vectors.zig");
const pack = @import("quality/pack.zig");

test "quality load vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try vectors.expectPassed(try vectors.loadVectors(arena.allocator(), paths.quality_load_vectors_dir, "quality", pack.parse));
}

test "quality scenario vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try vectors.expectPassed(try vectors.scenarioVectors(api.Module(.quality), arena.allocator(), paths.packs_dir, "quality-"));
}
