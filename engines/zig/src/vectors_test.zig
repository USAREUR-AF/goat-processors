// spec/vector-format.md: every correlate load vector and every scenario vector of
// the packs/correlate-* packs, through the entry point of api.zig.
const std = @import("std");
const paths = @import("paths");
const api = @import("api.zig");
const vectors = @import("io/vectors.zig");
const pack = @import("correlate/pack.zig");

test "correlate load vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try vectors.expectPassed(try vectors.loadVectors(arena.allocator(), paths.load_vectors_dir, "correlate", pack.parse));
}

test "correlate scenario vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try vectors.expectPassed(try vectors.scenarioVectors(api.Module(.correlate), arena.allocator(), paths.packs_dir, "correlate-"));
}
