const std = @import("std");

/// Build graph for sigil — Marks that carry meaning — serialization and configuration formats for Zig
///
/// Steps:
///   zig build            — build library + CLI
///   zig build test       — run all unit tests
///   zig build bench      — run benchmarks (ReleaseFast recommended)
///   zig build docs       — generate API docs into zig-out/docs
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module — consumers `@import("sigil")`
    const mod = b.addModule("sigil", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // CLI executable (diagnostics, version, small utilities)
    const exe = b.addExecutable(.{
        .name = "sigil",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sigil", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Tests
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    addTidyStep(b, test_step);

    // Benchmarks
    const bench = b.addExecutable(.{
        .name = "sigil-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "sigil", .module = mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Docs
    const docs = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&docs.step);
}

/// Wires the Tiger Style lint (`tools/tidy.zig`): its own unit tests run as
/// part of `test_step`, while the real repo-wide scan is its own `tidy`
/// step until plan 001 item 4 fixes today's known violations and makes it
/// a hard gate on `test`.
fn addTidyStep(b: *std.Build, test_step: *std.Build.Step) void {
    const tidy_mod = b.createModule(.{
        .root_source_file = b.path("tools/tidy.zig"),
        .target = b.graph.host,
    });
    const tidy_tests = b.addTest(.{ .root_module = tidy_mod });
    const run_tidy_tests = b.addRunArtifact(tidy_tests);
    test_step.dependOn(&run_tidy_tests.step);

    const tidy_exe = b.addExecutable(.{ .name = "tidy", .root_module = tidy_mod });
    const run_tidy = b.addRunArtifact(tidy_exe);
    run_tidy.addArgs(&.{ "--root", b.pathFromRoot(".") });
    const tidy_step = b.step("tidy", "Run the Tiger Style tidy lint over the repo");
    tidy_step.dependOn(&run_tidy.step);
}
