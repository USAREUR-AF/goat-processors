// spec/vector-format.md: every filter load vector and every scenario vector of
// the packs/filter-* packs, through the entry point of api.zig.
const std = @import("std");
const paths = @import("paths");
const api = @import("api.zig");
const vectors = @import("io/vectors.zig");
const pack = @import("filter/pack.zig");

test "filter load vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try vectors.expectPassed(try vectors.loadVectors(arena.allocator(), paths.filter_load_vectors_dir, "filter", pack.parse));
}

test "filter scenario vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try vectors.expectPassed(try vectors.scenarioVectors(api.Module(.filter), arena.allocator(), paths.packs_dir, "filter-"));
}
