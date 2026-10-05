const std = @import("std");
pub const Args = @import("args.zig");
pub const help = @import("help.zig");

pub const ExitCode = enum(u8) {
    ok = 0,
    schema = 1,
    usage = 2,
    stale = 3,
    io = 4,
    oom = 5,
    internal = 70,
};

/// argv excludes argv[0]. Output writers and arena lifetime belong to the caller.
pub fn run(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    version: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!ExitCode {
    const parsed = Args.parse(arena, argv) catch {
        try stderr.writeAll("cddl-zig: error: out of memory\n");
        return .oom;
    };
    const command = switch (parsed) {
        .ok => |command| command,
        .usage => |problem| {
            if (argv.len == 0) {
                try stderr.writeAll(help.usage);
            } else {
                try stderr.print("cddl-zig: error: {s}\n", .{problem.message});
            }
            return .usage;
        },
    };
    switch (command) {
        .help => |topic| try stdout.writeAll(help.text(topic)),
        .version => try stdout.print("cddl-zig {s}\n", .{version}),
        .check, .generate, .runtime, .explain => {
            try stderr.print("cddl-zig: error: command '{s}' is unavailable in this build\n", .{@tagName(command)});
            return .schema;
        },
    }
    return .ok;
}

fn expectRun(argv: []const []const u8, exit: ExitCode, out: []const u8, err: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    try std.testing.expectEqual(exit, try run(arena.allocator(), argv, "1.2.3-test", &stdout, &stderr));
    try std.testing.expectEqualStrings(out, stdout.buffered());
    try std.testing.expectEqualStrings(err, stderr.buffered());
}

test "version output and aliases are exact and stdout-only" {
    for ([_][]const []const u8{ &.{"version"}, &.{"--version"}, &.{"-V"} }) |argv| {
        try expectRun(argv, .ok, "cddl-zig 1.2.3-test\n", "");
    }
}

test "usage output is a stable single stderr line" {
    try expectRun(&.{}, .usage, "", "Usage: cddl-zig <command> [options]\n");
    try expectRun(&.{"unknown\ncommand"}, .usage, "", "cddl-zig: error: unknown command; use 'cddl-zig help'\n");
    try expectRun(&.{ "generate", "--check", "schema.cddl" }, .usage, "", "cddl-zig: error: --check requires --output with a file path, not stdout\n");
    try expectRun(&.{ "version", "extra" }, .usage, "", "cddl-zig: error: version does not accept arguments\n");
}

test "unavailable commands never succeed or write stdout" {
    try expectRun(&.{ "generate", "schema.cddl" }, .schema, "", "cddl-zig: error: command 'generate' is unavailable in this build\n");
    try expectRun(&.{ "check", "schema.cddl" }, .schema, "", "cddl-zig: error: command 'check' is unavailable in this build\n");
    try expectRun(&.{"runtime"}, .schema, "", "cddl-zig: error: command 'runtime' is unavailable in this build\n");
    try expectRun(&.{ "explain", "E0301" }, .schema, "", "cddl-zig: error: command 'explain' is unavailable in this build\n");
}

test "general help and aliases have exact output" {
    const expected =
        \\Usage: cddl-zig <command> [options]
        \\
        \\Generate Zig types and CBOR codecs from CDDL.
        \\
        \\Commands:
        \\  generate  Generate Zig source from schema files
        \\  check     Validate schema files without generating source
        \\  runtime   Write the standalone CBOR runtime
        \\  explain   Explain a diagnostic code
        \\  help      Show help for a command
        \\  version   Print the package version
        \\
        \\Options:
        \\  -h, --help     Show help
        \\  -V, --version  Print the package version
        \\
        \\Use 'cddl-zig help <command>' for command options.
        \\generate, check, runtime, and explain are unavailable in this build.
        \\Exit codes:
        \\  0  Success
        \\  1  Schema errors, denied warnings, or unavailable command
        \\  2  Invalid command-line usage
        \\  3  --check output is missing or differs
        \\  4  Input/output failure or input byte limit exceeded
        \\  5  Out of memory
        \\  70 Internal error
        \\
    ;
    for ([_][]const []const u8{ &.{"help"}, &.{"--help"}, &.{"-h"} }) |argv| {
        try expectRun(argv, .ok, expected, "");
    }
}

test "command help routing is exact and takes precedence over usage errors" {
    inline for (std.meta.tags(Args.Topic)) |topic| {
        try expectRun(&.{ "help", @tagName(topic) }, .ok, help.text(topic), "");
        try expectRun(&.{ @tagName(topic), "--help" }, .ok, help.text(topic), "");
        try expectRun(&.{ @tagName(topic), "--unknown", "-h", "extra" }, .ok, help.text(topic), "");
    }
    const expected =
        \\Usage: cddl-zig version
        \\
        \\Print 'cddl-zig <version>' followed by a newline.
        \\Aliases: --version, -V. No other arguments are accepted.
        \\
    ;
    try expectRun(&.{ "help", "version" }, .ok, expected, "");
}

test "output capacity failures propagate instead of reporting success" {
    var empty_buffer: [0]u8 = .{};
    var stderr_buffer: [128]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&empty_buffer);
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    try std.testing.expectError(error.WriteFailed, run(std.testing.allocator, &.{"version"}, "1.0.0", &stdout, &stderr));
}

test "allocation failures have their own exit code and exact message" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var stdout_buffer: [64]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    try std.testing.expectEqual(ExitCode.oom, try run(failing.allocator(), &.{ "check", "a" }, "1.0.0", &stdout, &stderr));
    try std.testing.expectEqualStrings("", stdout.buffered());
    try std.testing.expectEqualStrings("cddl-zig: error: out of memory\n", stderr.buffered());
}

test {
    _ = Args;
}

test "command help text snapshots" {
    const schema_options =
        \\  --root <rule>             Select a root rule (repeatable)
        \\  --opaque <rule>           Treat a rule as opaque (repeatable)
        \\  --stdin-name <name>       Source name for '-' input (default: <stdin>)
        \\  --color auto|always|never Diagnostic color (default: auto)
        \\  --diagnostics human|json  Diagnostic format (default: human)
        \\  --max-errors <u32>        Error limit; 0 is unlimited (default: 50)
        \\  --deny-warnings           Treat warnings as errors
        \\  --max-input-bytes <u32>   Input byte limit (default: 16777216)
        \\  -h, --help               Show command help, ignoring other usage errors
        \\  --                       End options; following arguments are file names
        \\
        \\Use '-' for stdin at most once. Long values accept --option=value.
        \\
    ;
    const generate =
        \\Usage: cddl-zig generate [options] [--] <file>...
        \\
        \\Generate Zig types and CBOR codecs. Unavailable in this build.
        \\
        \\Options:
        \\  -o, --output <path>       Output file, or '-' for stdout (default: '-')
        \\  --check                  Compare output without writing; requires a file
        \\  --runtime-import <name>   Runtime module name (default: cddl_runtime)
        \\  --no-header              Omit the generated-file header
        \\
    ;
    const check =
        \\Usage: cddl-zig check [options] [--] <file>...
        \\
        \\Validate CDDL without generating source. Unavailable in this build.
        \\
        \\Options:
        \\
    ;
    const runtime =
        \\Usage: cddl-zig runtime [-o <path>] [--check]
        \\
        \\Write the standalone CBOR runtime. Unavailable in this build.
        \\
        \\Options:
        \\  -o, --output <path>  Output file, or '-' for stdout (default: '-')
        \\  --check             Compare output without writing; requires a file
        \\  -h, --help          Show command help, ignoring other usage errors
        \\
        \\Long values accept --option=value.
        \\
    ;
    const explain =
        \\Usage: cddl-zig explain <CODE>
        \\
        \\Explain a diagnostic code. Unavailable in this build.
        \\Codes use E or W followed by four decimal digits (for example E0301).
        \\Use -h or --help to show this help.
        \\
    ;
    const help_command =
        \\Usage: cddl-zig help [<command>]
        \\
        \\Show general help or help for generate, check, runtime, explain, help,
        \\or version. The -h and --help aliases also show help.
        \\
    ;
    try expectRun(&.{ "help", "generate" }, .ok, generate ++ schema_options, "");
    try expectRun(&.{ "help", "check" }, .ok, check ++ schema_options, "");
    try expectRun(&.{ "help", "runtime" }, .ok, runtime, "");
    try expectRun(&.{ "help", "explain" }, .ok, explain, "");
    try expectRun(&.{ "help", "help" }, .ok, help_command, "");
}
