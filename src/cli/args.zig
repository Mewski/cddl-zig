const std = @import("std");
const codes = @import("codes.zig");

pub const Topic = enum { generate, check, runtime, explain, help, version };
pub const Color = enum { auto, always, never };
pub const DiagnosticsFormat = enum { human, json };
pub const Common = struct {
    color: Color = .auto,
    diagnostics_format: DiagnosticsFormat = .human,
    max_errors: u32 = 50,
    max_input_bytes: u32 = 16 * 1024 * 1024,
};
pub const Check = struct {
    common: Common = .{},
    /// A path, or `-` for stdin.
    input: []const u8,
    root: ?[]const u8 = null,
    stdin_name: []const u8 = "<stdin>",
};
pub const Generate = struct {
    schema: Check,
    output: []const u8 = "-",
    check: bool = false,
    runtime_import: []const u8 = "cddl_runtime",
    header: bool = true,
};
pub const Runtime = struct {
    /// Directory that receives the runtime source files.
    output: []const u8,
    check: bool = false,
};
pub const Command = union(enum) {
    generate: Generate,
    check: Check,
    runtime: Runtime,
    explain: codes.Code,
    help: ?Topic,
    version,
};
/// A usage error carries its stable message.
pub const Result = union(enum) { ok: Command, usage: []const u8 };

/// argv excludes the executable name. Strings borrow argv. No I/O, path
/// resolution, or schema-name lookup is performed.
pub fn parse(argv: []const []const u8) Result {
    if (argv.len == 0) return usage("expected a command; use 'cddl-zig help'");
    const first = argv[0];
    if (isHelp(first)) return .{ .ok = .{ .help = null } };
    const topic: Topic = if (eq(first, "--version") or eq(first, "-V")) .version else std.meta.stringToEnum(Topic, first) orelse return usage("unknown command; use 'cddl-zig help'");
    for (argv[1..]) |arg| {
        if (eq(arg, "--")) break;
        if (isHelp(arg)) return .{ .ok = .{ .help = topic } };
    }
    const rest = argv[1..];
    return switch (topic) {
        .help => parseHelp(rest),
        .version => if (rest.len == 0) .{ .ok = .version } else usage("version does not accept arguments"),
        .explain => parseExplain(rest),
        .runtime => parseRuntime(rest),
        .generate, .check => parseSchema(topic, rest),
    };
}

fn parseHelp(argv: []const []const u8) Result {
    if (argv.len == 0) return .{ .ok = .{ .help = null } };
    if (argv.len != 1) return usage("help accepts at most one command");
    const topic = std.meta.stringToEnum(Topic, argv[0]) orelse return usage("unknown help topic");
    return .{ .ok = .{ .help = topic } };
}

fn parseExplain(argv: []const []const u8) Result {
    if (argv.len != 1) return usage("explain requires one diagnostic code");
    return switch (codes.Code.parse(argv[0])) {
        .known => |code| .{ .ok = .{ .explain = code } },
        .unknown => usage("unknown diagnostic code"),
        .malformed => usage("diagnostic code must be E followed by four decimal digits"),
    };
}

const Option = struct {
    name: []const u8,
    inline_value: ?[]const u8 = null,

    fn from(arg: []const u8) Option {
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |index|
                return .{ .name = arg[0..index], .inline_value = arg[index + 1 ..] };
        }
        return .{ .name = arg };
    }

    fn value(self: Option, argv: []const []const u8, index: *usize) ?[]const u8 {
        if (self.inline_value) |v| return v;
        if (index.* + 1 >= argv.len or eq(argv[index.* + 1], "--")) return null;
        index.* += 1;
        return argv[index.*];
    }
};

fn parseRuntime(argv: []const []const u8) Result {
    var output: ?[]const u8 = null;
    var check = false;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const option = Option.from(argv[index]);
        if (eq(option.name, "--check")) {
            if (option.inline_value != null) return usage("--check does not accept a value");
            check = true;
        } else if (eq(option.name, "-o") or eq(option.name, "--output")) {
            const path = option.value(argv, &index) orelse return usage("--output requires a directory");
            if (path.len == 0) return usage("--output requires a non-empty directory");
            if (eq(path, "-")) return usage("--output must name a directory, not stdout");
            output = path;
        } else if (eq(option.name, "--") and option.inline_value == null and index + 1 == argv.len) {
            break;
        } else return usage("unknown runtime option or unexpected argument");
    }
    return .{ .ok = .{ .runtime = .{
        .output = output orelse return usage("runtime requires --output <directory>"),
        .check = check,
    } } };
}

fn parseSchema(topic: Topic, argv: []const []const u8) Result {
    var common: Common = .{};
    var input: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var stdin_name: ?[]const u8 = null;
    var generate: Generate = .{ .schema = .{ .input = "" } };
    var options = true;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (options and eq(arg, "--")) {
            options = false;
            continue;
        }
        if (!options or !std.mem.startsWith(u8, arg, "-") or eq(arg, "-")) {
            if (arg.len == 0) return usage("input path must not be empty");
            if (input != null) return usage("exactly one input file is accepted");
            input = arg;
            continue;
        }
        const option = Option.from(arg);
        const name = option.name;
        if (topic == .generate and (eq(name, "--check") or eq(name, "--no-header"))) {
            if (option.inline_value != null) return usage("flag does not accept a value");
            if (eq(name, "--check")) generate.check = true else generate.header = false;
            continue;
        }
        const common_value = eq(name, "--root") or eq(name, "--stdin-name") or eq(name, "--color") or
            eq(name, "--diagnostics") or eq(name, "--max-errors") or eq(name, "--max-input-bytes");
        const generate_value = topic == .generate and (eq(name, "-o") or eq(name, "--output") or eq(name, "--runtime-import"));
        if (!common_value and !generate_value) return usage("unknown option");
        const value = option.value(argv, &index) orelse return usage("option requires a value");
        if (eq(name, "--root")) {
            if (root != null) return usage("--root may be specified only once");
            if (value.len == 0) return usage("--root requires a rule name");
            root = value;
        } else if (eq(name, "--stdin-name")) {
            if (value.len == 0) return usage("--stdin-name requires a non-empty name");
            stdin_name = value;
        } else if (eq(name, "--color")) {
            common.color = std.meta.stringToEnum(Color, value) orelse return usage("--color must be auto, always, or never");
        } else if (eq(name, "--diagnostics")) {
            common.diagnostics_format = std.meta.stringToEnum(DiagnosticsFormat, value) orelse return usage("--diagnostics must be human or json");
        } else if (eq(name, "--max-errors")) {
            common.max_errors = decimal(value) orelse return usage("--max-errors must be an unsigned 32-bit decimal integer");
        } else if (eq(name, "--max-input-bytes")) {
            common.max_input_bytes = decimal(value) orelse return usage("--max-input-bytes must be an unsigned 32-bit decimal integer");
        } else if (eq(name, "--runtime-import")) {
            if (!validImport(value)) return usage("--runtime-import must be non-empty and contain no quotes, backslashes, or control bytes");
            generate.runtime_import = value;
        } else {
            if (value.len == 0) return usage("--output requires a non-empty path");
            generate.output = value;
        }
    }
    const path = input orelse return usage("an input file is required");
    if (stdin_name != null and !eq(path, "-")) return usage("--stdin-name requires stdin input '-'");
    if (generate.check and eq(generate.output, "-")) return usage("--check requires --output with a file path, not stdout");
    if (!eq(generate.output, "-") and eq(path, generate.output)) return usage("output path must not equal the input path");
    generate.schema = .{ .common = common, .input = path, .root = root, .stdin_name = stdin_name orelse "<stdin>" };
    return .{ .ok = if (topic == .generate) .{ .generate = generate } else .{ .check = generate.schema } };
}

fn decimal(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(u32, value, 10) catch null;
}

fn validImport(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (byte == '"' or byte == '\\' or byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn isHelp(arg: []const u8) bool {
    return eq(arg, "-h") or eq(arg, "--help");
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usage(message: []const u8) Result {
    return .{ .usage = message };
}

test "help and version aliases parse exactly" {
    const testing = std.testing;
    for ([_][]const []const u8{ &.{"help"}, &.{"--help"}, &.{"-h"} }) |argv| {
        try testing.expectEqual(Command{ .help = null }, parse(argv).ok);
    }
    for ([_][]const []const u8{ &.{"version"}, &.{"--version"}, &.{"-V"} }) |argv| {
        try testing.expectEqual(Command.version, parse(argv).ok);
    }
    inline for (std.meta.tags(Topic)) |topic| {
        try testing.expectEqual(Command{ .help = topic }, parse(&.{ "help", @tagName(topic) }).ok);
        try testing.expectEqual(Command{ .help = topic }, parse(&.{ @tagName(topic), "--bad", "--help" }).ok);
    }
}

test "generate parses all options and borrows strings" {
    const result = parse(&.{ "generate", "--root=first", "-o", "out.zig", "--check", "--no-header", "--runtime-import=wire", "--stdin-name", "pipe", "--color", "never", "-", "--diagnostics", "json", "--max-errors", "0", "--max-input-bytes=4294967295" }).ok.generate;
    try std.testing.expectEqualStrings("out.zig", result.output);
    try std.testing.expect(result.check and !result.header);
    try std.testing.expectEqualStrings("wire", result.runtime_import);
    try std.testing.expectEqualStrings("pipe", result.schema.stdin_name);
    try std.testing.expectEqualStrings("-", result.schema.input);
    try std.testing.expectEqualStrings("first", result.schema.root.?);
    try std.testing.expectEqualDeep(Common{
        .color = .never,
        .diagnostics_format = .json,
        .max_errors = 0,
        .max_input_bytes = std.math.maxInt(u32),
    }, result.schema.common);
    try std.testing.expectEqualStrings("--help", parse(&.{ "check", "--", "--help" }).ok.check.input);
}

test "explicit command defaults" {
    const generate = parse(&.{ "generate", "schema.cddl" }).ok.generate;
    try std.testing.expectEqualStrings("-", generate.output);
    try std.testing.expectEqualStrings("cddl_runtime", generate.runtime_import);
    try std.testing.expect(generate.header and !generate.check);
    try std.testing.expect(generate.schema.root == null);
    const check = parse(&.{ "check", "-" }).ok.check;
    try std.testing.expectEqualDeep(Common{}, check.common);
    try std.testing.expectEqualStrings("<stdin>", check.stdin_name);
    try std.testing.expectEqual(codes.Code.unknown_name, parse(&.{ "explain", "E0301" }).ok.explain);
    const runtime = parse(&.{ "runtime", "--output=vendor/cddl", "--check" }).ok.runtime;
    try std.testing.expect(runtime.check);
    try std.testing.expectEqualStrings("vendor/cddl", runtime.output);
    try std.testing.expect(!parse(&.{ "runtime", "-o", "dir" }).ok.runtime.check);
}

test "usage errors have stable messages" {
    const Case = struct { argv: []const []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .argv = &.{}, .message = "expected a command; use 'cddl-zig help'" },
        .{ .argv = &.{"unknown\ncommand"}, .message = "unknown command; use 'cddl-zig help'" },
        .{ .argv = &.{ "version", "extra" }, .message = "version does not accept arguments" },
        .{ .argv = &.{ "help", "unknown" }, .message = "unknown help topic" },
        .{ .argv = &.{ "help", "check", "generate" }, .message = "help accepts at most one command" },
        .{ .argv = &.{"check"}, .message = "an input file is required" },
        .{ .argv = &.{ "check", "a", "b" }, .message = "exactly one input file is accepted" },
        .{ .argv = &.{ "check", "-", "-" }, .message = "exactly one input file is accepted" },
        .{ .argv = &.{ "check", "" }, .message = "input path must not be empty" },
        .{ .argv = &.{ "check", "--no-header", "a" }, .message = "unknown option" },
        .{ .argv = &.{ "check", "--opaque=x", "a" }, .message = "unknown option" },
        .{ .argv = &.{ "check", "--deny-warnings", "a" }, .message = "unknown option" },
        .{ .argv = &.{ "check", "--color" }, .message = "option requires a value" },
        .{ .argv = &.{ "check", "--root", "--", "a" }, .message = "option requires a value" },
        .{ .argv = &.{ "check", "--root=a", "--root=b", "a" }, .message = "--root may be specified only once" },
        .{ .argv = &.{ "check", "--root=", "a" }, .message = "--root requires a rule name" },
        .{ .argv = &.{ "check", "--color=bad", "a" }, .message = "--color must be auto, always, or never" },
        .{ .argv = &.{ "check", "--diagnostics=xml", "a" }, .message = "--diagnostics must be human or json" },
        .{ .argv = &.{ "check", "--max-errors=4294967296", "a" }, .message = "--max-errors must be an unsigned 32-bit decimal integer" },
        .{ .argv = &.{ "check", "--max-errors=-1", "a" }, .message = "--max-errors must be an unsigned 32-bit decimal integer" },
        .{ .argv = &.{ "check", "--max-input-bytes=1_000", "a" }, .message = "--max-input-bytes must be an unsigned 32-bit decimal integer" },
        .{ .argv = &.{ "check", "--stdin-name=x", "a" }, .message = "--stdin-name requires stdin input '-'" },
        .{ .argv = &.{ "check", "--stdin-name=", "-" }, .message = "--stdin-name requires a non-empty name" },
        .{ .argv = &.{ "generate", "--check", "a" }, .message = "--check requires --output with a file path, not stdout" },
        .{ .argv = &.{ "generate", "--check=yes", "-o", "b", "a" }, .message = "flag does not accept a value" },
        .{ .argv = &.{ "generate", "-o", "a", "a" }, .message = "output path must not equal the input path" },
        .{ .argv = &.{ "generate", "--runtime-import=bad\nname", "a" }, .message = "--runtime-import must be non-empty and contain no quotes, backslashes, or control bytes" },
        .{ .argv = &.{"runtime"}, .message = "runtime requires --output <directory>" },
        .{ .argv = &.{ "runtime", "--check" }, .message = "runtime requires --output <directory>" },
        .{ .argv = &.{ "runtime", "-o" }, .message = "--output requires a directory" },
        .{ .argv = &.{ "runtime", "-o", "-" }, .message = "--output must name a directory, not stdout" },
        .{ .argv = &.{ "runtime", "a" }, .message = "unknown runtime option or unexpected argument" },
        .{ .argv = &.{"explain"}, .message = "explain requires one diagnostic code" },
        .{ .argv = &.{ "explain", "e0301" }, .message = "diagnostic code must be E followed by four decimal digits" },
        .{ .argv = &.{ "explain", "W0001" }, .message = "diagnostic code must be E followed by four decimal digits" },
        .{ .argv = &.{ "explain", "E9999" }, .message = "unknown diagnostic code" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.message, parse(case.argv).usage);
}
