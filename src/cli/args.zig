const std = @import("std");

pub const Topic = enum { generate, check, runtime, explain, help, version };
pub const Color = enum { auto, always, never };
pub const DiagnosticsFormat = enum { human, json };
pub const Common = struct {
    color: Color = .auto,
    diagnostics_format: DiagnosticsFormat = .human,
    max_errors: u32 = 50,
    deny_warnings: bool = false,
    max_input_bytes: u32 = 16 * 1024 * 1024,
};
pub const Check = struct {
    common: Common = .{},
    inputs: []const []const u8 = &.{},
    roots: []const []const u8 = &.{},
    opaque_rules: []const []const u8 = &.{},
    stdin_name: []const u8 = "<stdin>",
};
pub const Generate = struct {
    schema: Check = .{},
    output: []const u8 = "-",
    check: bool = false,
    runtime_import: []const u8 = "cddl_runtime",
    header: bool = true,
};
pub const Runtime = struct {
    output: []const u8 = "-",
    check: bool = false,
};
pub const Command = union(enum) {
    generate: Generate,
    check: Check,
    runtime: Runtime,
    explain: []const u8,
    help: ?Topic,
    version,
};
pub const UsageError = struct {
    message: []const u8,
    help_topic: ?Topic,
};
pub const Result = union(enum) { ok: Command, usage: UsageError };

/// argv excludes the executable name. Strings borrow argv; collection storage
/// belongs to arena. No I/O, path resolution, or schema-name lookup is performed.
pub fn parse(arena: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error!Result {
    if (argv.len == 0) return usage(null, "expected a command; use 'cddl-zig help'");
    const first = argv[0];
    if (isHelp(first)) return .{ .ok = .{ .help = null } };
    const topic: Topic = if (eq(first, "--version") or eq(first, "-V")) .version else std.meta.stringToEnum(Topic, first) orelse return usage(null, "unknown command; use 'cddl-zig help'");
    for (argv[1..]) |arg| {
        if (eq(arg, "--")) break;
        if (isHelp(arg)) return .{ .ok = .{ .help = topic } };
    }
    const rest = argv[1..];
    return switch (topic) {
        .help => parseHelp(rest),
        .version => if (rest.len == 0) .{ .ok = .version } else usage(.version, "version does not accept arguments"),
        .explain => parseExplain(rest),
        .runtime => parseRuntime(rest),
        .generate, .check => try parseSchema(arena, topic, rest),
    };
}

fn parseHelp(argv: []const []const u8) Result {
    if (argv.len == 0) return .{ .ok = .{ .help = null } };
    if (argv.len != 1) return usage(.help, "help accepts at most one command");
    const topic = std.meta.stringToEnum(Topic, argv[0]) orelse return usage(.help, "unknown help topic");
    return .{ .ok = .{ .help = topic } };
}

fn parseExplain(argv: []const []const u8) Result {
    if (argv.len != 1) return usage(.explain, "explain requires one diagnostic code");
    const code = argv[0];
    if (code.len != 5 or (code[0] != 'E' and code[0] != 'W'))
        return usage(.explain, "diagnostic code must be E or W followed by four decimal digits");
    for (code[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return usage(.explain, "diagnostic code must be E or W followed by four decimal digits");
    }
    return .{ .ok = .{ .explain = code } };
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
    var result: Runtime = .{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const option = Option.from(argv[index]);
        if (eq(option.name, "--check")) {
            if (option.inline_value != null) return usage(.runtime, "--check does not accept a value");
            result.check = true;
        } else if (eq(option.name, "-o") or eq(option.name, "--output")) {
            result.output = option.value(argv, &index) orelse return usage(.runtime, "--output requires a path");
            if (result.output.len == 0) return usage(.runtime, "--output requires a non-empty path");
        } else if (eq(option.name, "--") and option.inline_value == null and index + 1 == argv.len) {
            break;
        } else return usage(.runtime, "unknown runtime option or unexpected argument");
    }
    if (result.check and eq(result.output, "-")) return usage(.runtime, "--check requires --output with a file path, not stdout");
    return .{ .ok = .{ .runtime = result } };
}

fn parseSchema(arena: std.mem.Allocator, topic: Topic, argv: []const []const u8) std.mem.Allocator.Error!Result {
    var result: Generate = .{};
    var inputs: std.ArrayList([]const u8) = .empty;
    var roots: std.ArrayList([]const u8) = .empty;
    var opaque_rules: std.ArrayList([]const u8) = .empty;
    var stdin_seen = false;
    var stdin_named = false;
    var options = true;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (options and eq(arg, "--")) {
            options = false;
            continue;
        }
        if (!options or !std.mem.startsWith(u8, arg, "-") or eq(arg, "-")) {
            if (arg.len == 0) return usage(topic, "input path must not be empty");
            if (eq(arg, "-")) {
                if (stdin_seen) return usage(topic, "stdin input '-' may be specified only once");
                stdin_seen = true;
            }
            try inputs.append(arena, arg);
            continue;
        }
        const option = Option.from(arg);
        const name = option.name;
        if (eq(name, "--deny-warnings") or
            (topic == .generate and (eq(name, "--check") or eq(name, "--no-header"))))
        {
            if (option.inline_value != null) return usage(topic, "flag does not accept a value");
            if (eq(name, "--deny-warnings")) result.schema.common.deny_warnings = true;
            if (eq(name, "--check")) result.check = true;
            if (eq(name, "--no-header")) result.header = false;
            continue;
        }
        const common_value = eq(name, "--root") or eq(name, "--opaque") or eq(name, "--stdin-name") or
            eq(name, "--color") or eq(name, "--diagnostics") or eq(name, "--max-errors") or eq(name, "--max-input-bytes");
        const generate_value = topic == .generate and (eq(name, "-o") or eq(name, "--output") or eq(name, "--runtime-import"));
        if (!common_value and !generate_value) return usage(topic, "unknown option");
        const value = option.value(argv, &index) orelse return usage(topic, "option requires a value");
        if (eq(name, "--root")) {
            try roots.append(arena, value);
        } else if (eq(name, "--opaque")) {
            try opaque_rules.append(arena, value);
        } else if (eq(name, "--stdin-name")) {
            if (value.len == 0) return usage(topic, "--stdin-name requires a non-empty name");
            result.schema.stdin_name = value;
            stdin_named = true;
        } else if (eq(name, "--color")) {
            result.schema.common.color = std.meta.stringToEnum(Color, value) orelse return usage(topic, "--color must be auto, always, or never");
        } else if (eq(name, "--diagnostics")) {
            result.schema.common.diagnostics_format = std.meta.stringToEnum(DiagnosticsFormat, value) orelse return usage(topic, "--diagnostics must be human or json");
        } else if (eq(name, "--max-errors")) {
            result.schema.common.max_errors = decimal(value) orelse return usage(topic, "--max-errors must be an unsigned 32-bit decimal integer");
        } else if (eq(name, "--max-input-bytes")) {
            result.schema.common.max_input_bytes = decimal(value) orelse return usage(topic, "--max-input-bytes must be an unsigned 32-bit decimal integer");
        } else if (eq(name, "--runtime-import")) {
            if (!validImport(value)) return usage(topic, "--runtime-import must be non-empty and contain no quotes, backslashes, or control bytes");
            result.runtime_import = value;
        } else {
            if (value.len == 0) return usage(topic, "--output requires a non-empty path");
            result.output = value;
        }
    }
    if (inputs.items.len == 0) return usage(topic, "at least one input file is required");
    if (stdin_named and !stdin_seen) return usage(topic, "--stdin-name requires stdin input '-'");
    if (result.check and eq(result.output, "-")) return usage(topic, "--check requires --output with a file path, not stdout");
    if (topic == .generate and !eq(result.output, "-")) {
        for (inputs.items) |input| {
            if (eq(input, result.output)) return usage(topic, "output path must not equal an input path");
        }
    }
    result.schema.inputs = inputs.items;
    result.schema.roots = roots.items;
    result.schema.opaque_rules = opaque_rules.items;
    return .{ .ok = if (topic == .generate) .{ .generate = result } else .{ .check = result.schema } };
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

fn usage(topic: ?Topic, message: []const u8) Result {
    return .{ .usage = .{ .message = message, .help_topic = topic } };
}

test "help and version aliases parse exactly" {
    const testing = std.testing;
    for ([_][]const []const u8{ &.{"help"}, &.{"--help"}, &.{"-h"} }) |argv| {
        const result = try parse(testing.allocator, argv);
        try testing.expectEqual(Command{ .help = null }, result.ok);
    }
    for ([_][]const []const u8{ &.{"version"}, &.{"--version"}, &.{"-V"} }) |argv| {
        try testing.expectEqual(Command.version, (try parse(testing.allocator, argv)).ok);
    }
    inline for (std.meta.tags(Topic)) |topic| {
        try testing.expectEqual(Command{ .help = topic }, (try parse(testing.allocator, &.{ "help", @tagName(topic) })).ok);
        try testing.expectEqual(Command{ .help = topic }, (try parse(testing.allocator, &.{ @tagName(topic), "--bad", "--help" })).ok);
    }
}

test "generate parses all options, borrows strings, and preserves order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = (try parse(arena.allocator(), &.{
        "generate",      "a.cddl",  "--root=first", "--root",      "second",                "--opaque",                     "raw",
        "-o",            "out.zig", "--check",      "--no-header", "--runtime-import=wire", "--stdin-name=pipe",            "--color=never",
        "--diagnostics", "json",    "--max-errors", "0",           "--deny-warnings",       "--max-input-bytes=4294967295", "-",
        "--",            "--help",
    })).ok.generate;
    try std.testing.expectEqualStrings("out.zig", result.output);
    try std.testing.expect(result.check and !result.header);
    try std.testing.expectEqualStrings("wire", result.runtime_import);
    try std.testing.expectEqualStrings("pipe", result.schema.stdin_name);
    try std.testing.expectEqual(@as(usize, 3), result.schema.inputs.len);
    try std.testing.expectEqualStrings("a.cddl", result.schema.inputs[0]);
    try std.testing.expectEqualStrings("-", result.schema.inputs[1]);
    try std.testing.expectEqualStrings("--help", result.schema.inputs[2]);
    try std.testing.expectEqual(@as(usize, 2), result.schema.roots.len);
    try std.testing.expectEqualStrings("first", result.schema.roots[0]);
    try std.testing.expectEqualStrings("second", result.schema.roots[1]);
    try std.testing.expectEqualStrings("raw", result.schema.opaque_rules[0]);
    try std.testing.expectEqualDeep(Common{
        .color = .never,
        .diagnostics_format = .json,
        .max_errors = 0,
        .deny_warnings = true,
        .max_input_bytes = std.math.maxInt(u32),
    }, result.schema.common);
}

test "explicit command defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const generate = (try parse(allocator, &.{ "generate", "schema.cddl" })).ok.generate;
    try std.testing.expectEqualStrings("-", generate.output);
    try std.testing.expectEqualStrings("cddl_runtime", generate.runtime_import);
    try std.testing.expect(generate.header and !generate.check);
    const check = (try parse(allocator, &.{ "check", "-" })).ok.check;
    try std.testing.expectEqualDeep(Common{}, check.common);
    try std.testing.expectEqualStrings("<stdin>", check.stdin_name);
    try std.testing.expectEqualDeep(Runtime{}, (try parse(allocator, &.{"runtime"})).ok.runtime);
    try std.testing.expectEqualStrings("E0301", (try parse(allocator, &.{ "explain", "E0301" })).ok.explain);
    const runtime = (try parse(allocator, &.{ "runtime", "--output=runtime.zig", "--check" })).ok.runtime;
    try std.testing.expect(runtime.check);
    try std.testing.expectEqualStrings("runtime.zig", runtime.output);
}

test "usage errors have stable exact messages and topics" {
    const Case = struct { argv: []const []const u8, topic: ?Topic, message: []const u8 };
    const cases = [_]Case{
        .{ .argv = &.{}, .topic = null, .message = "expected a command; use 'cddl-zig help'" },
        .{ .argv = &.{"unknown\ncommand"}, .topic = null, .message = "unknown command; use 'cddl-zig help'" },
        .{ .argv = &.{ "version", "extra" }, .topic = .version, .message = "version does not accept arguments" },
        .{ .argv = &.{ "help", "unknown" }, .topic = .help, .message = "unknown help topic" },
        .{ .argv = &.{ "help", "check", "generate" }, .topic = .help, .message = "help accepts at most one command" },
        .{ .argv = &.{"check"}, .topic = .check, .message = "at least one input file is required" },
        .{ .argv = &.{ "check", "--no-header", "a" }, .topic = .check, .message = "unknown option" },
        .{ .argv = &.{ "check", "--color" }, .topic = .check, .message = "option requires a value" },
        .{ .argv = &.{ "check", "--root", "--", "a" }, .topic = .check, .message = "option requires a value" },
        .{ .argv = &.{ "check", "--color=bad", "a" }, .topic = .check, .message = "--color must be auto, always, or never" },
        .{ .argv = &.{ "check", "--diagnostics=xml", "a" }, .topic = .check, .message = "--diagnostics must be human or json" },
        .{ .argv = &.{ "check", "--max-errors=4294967296", "a" }, .topic = .check, .message = "--max-errors must be an unsigned 32-bit decimal integer" },
        .{ .argv = &.{ "check", "--max-errors=-1", "a" }, .topic = .check, .message = "--max-errors must be an unsigned 32-bit decimal integer" },
        .{ .argv = &.{ "check", "--max-input-bytes=1_000", "a" }, .topic = .check, .message = "--max-input-bytes must be an unsigned 32-bit decimal integer" },
        .{ .argv = &.{ "check", "--deny-warnings=true", "a" }, .topic = .check, .message = "flag does not accept a value" },
        .{ .argv = &.{ "check", "-", "-" }, .topic = .check, .message = "stdin input '-' may be specified only once" },
        .{ .argv = &.{ "check", "--stdin-name=x", "a" }, .topic = .check, .message = "--stdin-name requires stdin input '-'" },
        .{ .argv = &.{ "generate", "--check", "a" }, .topic = .generate, .message = "--check requires --output with a file path, not stdout" },
        .{ .argv = &.{ "generate", "-o", "a", "a" }, .topic = .generate, .message = "output path must not equal an input path" },
        .{ .argv = &.{ "generate", "--runtime-import=bad\nname", "a" }, .topic = .generate, .message = "--runtime-import must be non-empty and contain no quotes, backslashes, or control bytes" },
        .{ .argv = &.{ "runtime", "--check" }, .topic = .runtime, .message = "--check requires --output with a file path, not stdout" },
        .{ .argv = &.{ "runtime", "-o" }, .topic = .runtime, .message = "--output requires a path" },
        .{ .argv = &.{ "runtime", "a" }, .topic = .runtime, .message = "unknown runtime option or unexpected argument" },
        .{ .argv = &.{"explain"}, .topic = .explain, .message = "explain requires one diagnostic code" },
        .{ .argv = &.{ "explain", "e0301" }, .topic = .explain, .message = "diagnostic code must be E or W followed by four decimal digits" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = (try parse(arena.allocator(), case.argv)).usage;
        try std.testing.expectEqual(case.topic, result.help_topic);
        try std.testing.expectEqualStrings(case.message, result.message);
    }
}

test "parser allocation failure is propagated" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parse(failing.allocator(), &.{ "check", "a" }));
}
