const std = @import("std");
const package = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const library = b.addModule("cddl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime = b.addModule("cddl_runtime", .{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", package.version);

    const executable = b.addExecutable(.{
        .name = "cddl-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cddl", .module = library },
                .{ .name = "cddl_runtime", .module = runtime },
            },
        }),
    });
    executable.root_module.addOptions("build_options", options);
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run cddl-zig (arguments after --)").dependOn(&run.step);

    const test_modules = [_]*std.Build.Module{
        library,
        runtime,
        executable.root_module,
    };

    const tests = b.step("test", "Run compiler, runtime, and CLI tests");
    for (test_modules) |module| {
        const unit_tests = b.addTest(.{ .root_module = module });
        tests.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    const format_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    const format = b.addFmt(.{ .paths = format_paths });
    b.step("fmt", "Format Zig sources").dependOn(&format.step);

    const format_check = b.addFmt(.{ .paths = format_paths, .check = true });
    b.step("fmt-check", "Check Zig source formatting").dependOn(&format_check.step);
}
