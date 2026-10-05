const Args = @import("args.zig");

pub const usage = "Usage: cddl-zig <command> [options]\n";
pub const exit_codes =
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

pub const overview = usage ++
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
    \\
++ exit_codes;

const common =
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

pub fn text(topic: ?Args.Topic) []const u8 {
    const command = topic orelse return overview;
    return switch (command) {
        .generate =>
        \\Usage: cddl-zig generate [options] [--] <file>...
        \\
        \\Generate Zig types and CBOR codecs. Unavailable in this build.
        \\
        \\Options:
        \\  -o, --output <path>       Output file, or '-' for stdout (default: '-')
        \\  --check                  Compare output without writing; requires a file
        \\  --runtime-import <name>   Runtime module name (default: cddl_runtime)
        \\  --no-header              Omit the generated-file header
        ++ "\n" ++ common,
        .check =>
        \\Usage: cddl-zig check [options] [--] <file>...
        \\
        \\Validate CDDL without generating source. Unavailable in this build.
        \\
        \\Options:
        ++ "\n" ++ common,
        .runtime =>
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
        ,
        .explain =>
        \\Usage: cddl-zig explain <CODE>
        \\
        \\Explain a diagnostic code. Unavailable in this build.
        \\Codes use E or W followed by four decimal digits (for example E0301).
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
