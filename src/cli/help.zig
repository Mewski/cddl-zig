const std = @import("std");
const args = @import("args.zig");

pub const usage = "Usage: cddl-zig <command> [options]\n";
pub const exit_codes =
    \\Exit codes:
    \\  0  Success
    \\  1  Schema diagnostics
    \\  2  Invalid usage, unknown diagnostic code, or output that is the input
    \\  3  --check output is missing or differs
    \\  4  Input/output failure or input byte limit exceeded
    \\  5  Out of memory
    \\  70 Internal error
    \\
;

pub const overview = usage ++
    \\
    \\Generate Zig types and CBOR codecs from CDDL.
    \\
    \\Commands:
    \\  generate  Generate Zig source from a schema file
    \\  check     Validate a schema file without writing output
    \\  runtime   Write the standalone CBOR runtime sources
    \\  explain   Explain a diagnostic code
    \\  help      Show help for a command
    \\  version   Print the package version
    \\
    \\Options:
    \\  -h, --help     Show help
    \\  -V, --version  Print the package version
    \\
    \\Use 'cddl-zig help <command>' for command options.
    \\
    \\
++ exit_codes;

const schema_options =
    \\  --root <rule>              Select the root rule (default: first rule)
    \\  --stdin-name <name>        Source name for '-' input (default: <stdin>)
    \\  --color auto|always|never  Diagnostic color (default: auto)
    \\  --diagnostics human|json   Diagnostic format (default: human)
    \\  --max-errors <u32>         Diagnostics shown; 0 is unlimited (default: 50)
    \\  --max-input-bytes <u32>    Input byte limit (default: 16777216)
    \\  -h, --help                 Show command help, ignoring other usage errors
    \\  --                         End options; the next argument is the input
    \\
    \\The input is one schema file, or '-' for stdin. Long values accept
    \\--option=value. Color 'auto' applies when stderr is a terminal and NO_COLOR
    \\is unset. Human diagnostics are 'name:line:column: error[CODE]: message'
    \\lines; json writes exactly one document to stderr, also for I/O errors:
    \\{"diagnostics":[...],"total":N,"omitted":N,"error":null|"message"}.
    \\Lines and byte columns are one-based.
    \\
;

pub fn text(topic: ?args.Topic) []const u8 {
    const command = topic orelse return overview;
    return switch (command) {
        .generate =>
        \\Usage: cddl-zig generate [options] [--] <file>
        \\
        \\Generate Zig types and CBOR codecs from one CDDL schema. A file output is
        \\replaced atomically and only when its content changes.
        \\
        \\Options:
        \\  -o, --output <path>        Output file, or '-' for stdout (default: '-')
        \\  --check                    Compare the output file without writing it
        \\  --runtime-import <name>    Runtime module name (default: cddl_runtime)
        \\  --no-header                Omit the generated-file header
        ++ "\n" ++ schema_options,
        .check =>
        \\Usage: cddl-zig check [options] [--] <file>
        \\
        \\Validate one CDDL schema through code generation without writing output.
        \\
        \\Options:
        ++ "\n" ++ schema_options,
        .runtime =>
        \\Usage: cddl-zig runtime -o <directory> [--check]
        \\
        \\Write the standalone CBOR runtime sources into <directory>, creating it
        \\when missing. The module root is <directory>/root.zig. Each runtime file
        \\is replaced atomically and only when its content changes; other files in
        \\the directory are left untouched.
        \\
        \\Options:
        \\  -o, --output <directory>  Runtime source directory (required)
        \\  --check                   Report missing or differing files; write nothing
        \\  -h, --help                Show command help, ignoring other usage errors
        \\
        \\Long values accept --option=value.
        \\
        ,
        .explain =>
        \\Usage: cddl-zig explain <CODE>
        \\
        \\Print a one-line explanation of a diagnostic code.
        \\Codes are E followed by four decimal digits (for example E0301).
        \\Use -h or --help to show this help.
        \\
        ,
        .help =>
        \\Usage: cddl-zig help [<command>]
        \\
        \\Show general help or help for generate, check, runtime, explain, help,
        \\or version. The -h and --help aliases also show help.
        \\
        ,
        .version =>
        \\Usage: cddl-zig version
        \\
        \\Print 'cddl-zig <version>' followed by a newline.
        \\Aliases: --version, -V. No other arguments are accepted.
        \\
        ,
    };
}

test "option descriptions share one column per help text" {
    const topics = [_]?args.Topic{ null, .generate, .check, .runtime, .explain, .help, .version };
    for (topics) |topic| {
        var column: ?usize = null;
        var lines = std.mem.splitScalar(u8, text(topic), '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "  -")) continue;
            const gap = std.mem.indexOfPos(u8, line, 2, "  ").?;
            const start = std.mem.indexOfNonePos(u8, line, gap, " ").?;
            if (column) |expected| try std.testing.expectEqual(expected, start) else column = start;
        }
    }
}

test "help lines are ASCII, newline-terminated, and at most 80 columns" {
    const topics = [_]?args.Topic{ null, .generate, .check, .runtime, .explain, .help, .version };
    for (topics) |topic| {
        const help = text(topic);
        try std.testing.expect(std.mem.endsWith(u8, help, "\n"));
        var lines = std.mem.splitScalar(u8, help, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(line.len <= 80);
            for (line) |byte| try std.testing.expect(byte >= 0x20 and byte < 0x7f);
        }
    }
}
