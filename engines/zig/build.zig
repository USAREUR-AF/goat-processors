const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const packs_dir = b.option([]const u8, "packs", "packs directory") orelse b.pathFromRoot("../../packs");
    const load_vectors_dir = b.option([]const u8, "load-vectors", "load vectors directory") orelse b.pathFromRoot("../../spec/correlate-load-vectors");

    const quality_load_vectors_dir = b.option([]const u8, "quality-load-vectors", "quality load vectors directory") orelse b.pathFromRoot("../../spec/quality-load-vectors");
    const filter_load_vectors_dir = b.option([]const u8, "filter-load-vectors", "filter load vectors directory") orelse b.pathFromRoot("../../spec/filter-load-vectors");

    const options = b.addOptions();
    options.addOption([]const u8, "packs_dir", packs_dir);
    options.addOption([]const u8, "load_vectors_dir", load_vectors_dir);
    options.addOption([]const u8, "quality_load_vectors_dir", quality_load_vectors_dir);
    options.addOption([]const u8, "filter_load_vectors_dir", filter_load_vectors_dir);
    const fuse_load_vectors_dir = b.option([]const u8, "fuse-load-vectors", "fuse load vectors directory") orelse b.pathFromRoot("../../spec/fuse-load-vectors");
    options.addOption([]const u8, "fuse_load_vectors_dir", fuse_load_vectors_dir);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/vectors_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addOptions("paths", options);

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;

    // spec/quality.md: the quality load vectors and the packs/quality-* vectors.
    const quality_tests = b.addTest(.{
        .root_source_file = b.path("src/quality_vectors_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    quality_tests.root_module.addOptions("paths", options);
    const run_quality_tests = b.addRunArtifact(quality_tests);
    run_quality_tests.has_side_effects = true;

    // spec/fuse.md: the fuse load vectors and packs/fuse-* scenario vectors.
    const fuse_tests = b.addTest(.{
        .root_source_file = b.path("src/fuse_vectors_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuse_tests.root_module.addOptions("paths", options);
    const run_fuse_tests = b.addRunArtifact(fuse_tests);
    run_fuse_tests.has_side_effects = true;

    // spec/filter.md: the filter function, its own module and test.
    const filter_tests = b.addTest(.{
        .root_source_file = b.path("src/filter_vectors_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    filter_tests.root_module.addOptions("paths", options);
    const run_filter_tests = b.addRunArtifact(filter_tests);
    run_filter_tests.has_side_effects = true;

    const test_step = b.step("test", "Run every load vector and scenario vector: correlate, fuse, filter and quality");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_fuse_tests.step);
    test_step.dependOn(&run_filter_tests.step);
    test_step.dependOn(&run_quality_tests.step);
}
