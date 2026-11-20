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

    // Property tests over every scenario vector, and the parsers' fuzzing.
    const property_tests = b.addTest(.{
        .root_source_file = b.path("src/property_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    property_tests.root_module.addOptions("paths", options);
    const run_property_tests = b.addRunArtifact(property_tests);
    run_property_tests.has_side_effects = true;

    const fuzz_tests = b.addTest(.{
        .root_source_file = b.path("src/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_tests.root_module.addOptions("paths", options);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    run_fuzz_tests.has_side_effects = true;

    // The unit tests of every module.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/unit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true;

    // The runner of tools/perf/README.md "Runner contract" (runner/build builds it ReleaseFast).
    const runner = b.addExecutable(.{
        .name = "goat-runner",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(runner);

    // coverage/run.sh: the test binaries and the runner, built and installed
    // (not run) under zig-out/coverage/.
    const coverage_step = b.step("coverage-bins", "Install the test binaries and the runner for coverage/run.sh");
    const bins = [_]struct { c: *std.Build.Step.Compile, name: []const u8 }{
        .{ .c = tests, .name = "vectors" },
        .{ .c = filter_tests, .name = "filter_vectors" },
        .{ .c = fuse_tests, .name = "fuse_vectors" },
        .{ .c = quality_tests, .name = "quality_vectors" },
        .{ .c = unit_tests, .name = "unit" },
        .{ .c = property_tests, .name = "property" },
        .{ .c = fuzz_tests, .name = "fuzz" },
        .{ .c = runner, .name = "runner" },
    };
    for (bins) |x| {
        const install = b.addInstallArtifact(x.c, .{ .dest_dir = .{ .override = .{ .custom = "coverage" } }, .dest_sub_path = x.name });
        coverage_step.dependOn(&install.step);
    }

    const test_step = b.step("test", "Run every load vector and scenario vector: correlate, fuse, filter and quality");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_fuse_tests.step);
    test_step.dependOn(&run_filter_tests.step);
    test_step.dependOn(&run_quality_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_property_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
}
