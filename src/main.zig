const std = @import("std");
const cddl_runtime = @import("cddl_runtime");
const cddl = @import("cddl");
const cli = @import("cli/root.zig");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);

    const arena = init.arena.allocator();
    const arguments = init.minimal.args.toSlice(arena) catch |err| {
        const out_of_memory = err == error.OutOfMemory;
        stderr.interface.writeAll(if (out_of_memory)
            "cddl-zig: error: out of memory\n"
        else
            "cddl-zig: error: cannot read process arguments\n") catch return @intFromEnum(cli.ExitCode.io);
        stderr.interface.flush() catch return @intFromEnum(cli.ExitCode.io);

        return @intFromEnum(if (out_of_memory) cli.ExitCode.oom else cli.ExitCode.io);
    };

    const no_color = if (init.environ_map.get("NO_COLOR")) |value| value.len != 0 else false;
    const terminal = std.Io.Terminal.Mode.detect(io, std.Io.File.stderr(), no_color, false) catch .no_color;

    const command_arguments = if (arguments.len == 0) arguments else arguments[1..];
    const code = cli.run(arena, command_arguments, build_options.version, .{
        .io = io,
        .dir = std.Io.Dir.cwd(),
        .stdin = &stdin.interface,
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
        .stderr_color = terminal == .escape_codes,
    }) catch return @intFromEnum(cli.ExitCode.io);

    stderr.interface.flush() catch return @intFromEnum(cli.ExitCode.io);
    stdout.interface.flush() catch return @intFromEnum(cli.ExitCode.io);

    return @intFromEnum(code);
}

test "compiler targets the runtime ABI" {
    try std.testing.expectEqual(cddl_runtime.abi_version, cddl.runtime_abi);
}

test {
    _ = cli;
}
