const std = @import("std");
const cli = @import("cli/root.zig");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch |err| {
        const out_of_memory = err == error.OutOfMemory;
        stderr.interface.writeAll(if (out_of_memory)
            "cddl-zig: error: out of memory\n"
        else
            "cddl-zig: error: cannot read process arguments\n") catch return @intFromEnum(cli.ExitCode.io);
        stderr.interface.flush() catch return @intFromEnum(cli.ExitCode.io);
        return @intFromEnum(if (out_of_memory) cli.ExitCode.oom else cli.ExitCode.io);
    };
    const args = if (argv.len == 0) argv else argv[1..];
    const code = cli.run(arena, args, build_options.version, &stdout.interface, &stderr.interface) catch
        return @intFromEnum(cli.ExitCode.io);
    stderr.interface.flush() catch return @intFromEnum(cli.ExitCode.io);
    stdout.interface.flush() catch return @intFromEnum(cli.ExitCode.io);
    return @intFromEnum(code);
}

test {
    _ = cli;
}
