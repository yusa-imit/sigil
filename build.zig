const std = @import("std");

/// Build graph for sigil — Marks that carry meaning — serialization and configuration formats
/// for Zig
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
    addCompileErrorTests(b, test_step, mod, target);

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

/// A fixture under `tests/compile_errors/` and the message the compiler must reject it with.
const CompileErrorCase = struct { file: []const u8, message: []const u8 };

const compile_error_cases = [_]CompileErrorCase{
    .{
        .file = "unknown_option",
        .message = "unknown option .renmae (expected rename, rename_all or deny_unknown_fields)",
    },
    .{
        .file = "rename_missing_field",
        .message = "rename of .nmae, which is not a field or tag of the type",
    },
    .{ .file = "wire_name_collision", .message = "both land on the wire name \"x\"" },
    .{ .file = "rename_all_collision", .message = "both land on the wire name \"max-size\"" },
    .{ .file = "deny_on_enum", .message = "deny_unknown_fields applies to structs only" },
    .{ .file = "options_with_hooks", .message = "the options would be dead; remove one" },
    .{ .file = "rename_all_needs_snake_name", .message = "is not one; give it an explicit rename" },
    .{
        .file = "rename_all_unknown_style",
        .message = "is not one of snake_case, camel_case, pascal_case, kebab_case, " ++
            "screaming_snake_case",
    },
    .{ .file = "deny_not_bool", .message = "deny_unknown_fields must be a bool" },
    .{ .file = "rename_not_string", .message = "rename values must be string literals" },
    .{ .file = "rename_empty", .message = "rename of .name is empty" },
    .{
        .file = "rename_all_not_literal",
        .message = "rename_all must be an enum literal such as .kebab_case",
    },
    .{ .file = "rename_not_struct", .message = "rename must be an anonymous struct" },
    .{ .file = "options_not_struct", .message = "sigil_options must be an anonymous struct" },
    .{
        .file = "options_with_stringify_hook",
        .message = "the options would be dead; remove one",
    },
    .{ .file = "untagged_union", .message = "is unsupported" },
    .{ .file = "unsupported_type", .message = "is not a struct, enum or tagged union" },
    .{ .file = "parse_slice_u8", .message = "[]u8 is not supported" },
    .{ .file = "parse_int_128", .message = "i128 is not supported" },
    .{ .file = "parse_nested_optional", .message = "??u8 is not supported" },
    .{ .file = "parse_struct", .message = "is not supported" },
    .{ .file = "parse_nonexhaustive_enum", .message = "is not supported" },
    .{ .file = "parse_pointer", .message = "*const u8 is not supported" },
    .{ .file = "parse_f16", .message = "f16 is not supported" },
};

/// Compiles each `tests/compile_errors/<file>.zig` and passes only if the compiler rejects it
/// with the expected message, so a `@compileError` in `reflect` cannot silently stop firing.
fn addCompileErrorTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    for (compile_error_cases) |case| {
        const fixture = b.addObject(.{
            .name = case.file,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/compile_errors/{s}.zig", .{case.file})),
                .target = target,
                .imports = &.{.{ .name = "sigil", .module = mod }},
            }),
        });
        fixture.expect_errors = .{ .contains = case.message };
        test_step.dependOn(&fixture.step);
    }
}

/// Wires the Tiger Style lint (`tools/tidy.zig`): its own unit tests and the real repo-wide
/// scan are both hard dependencies of `test_step`, so a tidy violation fails `zig build test`.
/// `zig build tidy` remains available standalone for a scan without the rest of the suite.
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
    test_step.dependOn(&run_tidy.step);

    const tidy_step = b.step("tidy", "Run the Tiger Style tidy lint over the repo");
    tidy_step.dependOn(&run_tidy.step);
}
