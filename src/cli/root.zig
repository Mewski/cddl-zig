const std = @import("std");
const compiler = @import("cddl_zig").compiler;
const runtime_sources = @import("cddl_runtime").embed;
const args = @import("args.zig");
const help = @import("help.zig");
const codes = @import("codes.zig");
const report = @import("report.zig");
const Name = report.Name;

pub const ExitCode = enum(u8) {
    ok = 0,
    schema = 1,
    usage = 2,
    stale = 3,
    io = 4,
    oom = 5,
    internal = 70,
};

/// Process resources for one command. Relative paths resolve against `dir`.
pub const Process = struct {
    io: std.Io,
    dir: std.Io.Dir,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    /// Whether `--color=auto` colors diagnostics on stderr.
    stderr_color: bool,
};

const Error = std.Io.Writer.Error || std.mem.Allocator.Error;

/// argv excludes argv[0]. All allocations go to arena, which must outlive the call.
/// Output is buffered in the caller's writers; the caller flushes them.
pub fn run(arena: std.mem.Allocator, argv: []const []const u8, version: []const u8, process: Process) std.Io.Writer.Error!ExitCode {
    const command = switch (args.parse(argv)) {
        .ok => |command| command,
        .usage => |message| {
            if (argv.len == 0) {
                try process.stderr.writeAll(help.usage);
            } else {
                try process.stderr.print("cddl-zig: error: {s}\n", .{message});
            }
            return .usage;
        },
    };
    return execute(arena, command, version, process) catch |err| switch (err) {
        error.OutOfMemory => {
            // JSON output is deferred to the end of a command, so nothing has been written yet.
            if (jsonOutput(command)) {
                try report.writeJson(process.stderr, &.{}, 0, "out of memory");
            } else {
                try process.stderr.writeAll("cddl-zig: error: out of memory\n");
            }
            return .oom;
        },
        error.WriteFailed => return error.WriteFailed,
    };
}

fn jsonOutput(command: args.Command) bool {
    return switch (command) {
        .check => |options| options.common.diagnostics_format == .json,
        .generate => |options| options.schema.common.diagnostics_format == .json,
        .runtime, .explain, .help, .version => false,
    };
}

fn execute(arena: std.mem.Allocator, command: args.Command, version: []const u8, process: Process) Error!ExitCode {
    switch (command) {
        .help => |topic| try process.stdout.writeAll(help.text(topic)),
        .version => try process.stdout.print("cddl-zig {s}\n", .{version}),
        .explain => |code| try process.stdout.print("{f} {s}: {s}\n", .{ code, @tagName(code), code.explanation() }),
        .check => |options| {
            var reporter: Reporter = .init(arena, process, options.common);
            const exit: ExitCode = switch (try compile(&reporter, options, .{})) {
                .source => .ok,
                .exit => |code| code,
            };
            return reporter.finish(exit);
        },
        .generate => |options| {
            var reporter: Reporter = .init(arena, process, options.schema.common);
            return reporter.finish(try generate(&reporter, options));
        },
        .runtime => |options| {
            var reporter: Reporter = .init(arena, process, .{});
            return reporter.finish(try runtime(&reporter, options));
        },
    }
    return .ok;
}

/// Reports the outcome of one file command on stderr. Human output is written
/// as it happens. JSON output is one document written by `finish`; it carries
/// the diagnostics and the first non-diagnostic error.
const Reporter = struct {
    arena: std.mem.Allocator,
    process: Process,
    common: args.Common,
    findings: []const report.Finding = &.{},
    total: usize = 0,
    failure: ?[]const u8 = null,

    fn init(arena: std.mem.Allocator, process: Process, common: args.Common) Reporter {
        return .{ .arena = arena, .process = process, .common = common };
    }

    fn diagnostics(self: *Reporter, findings: []const report.Finding, total: usize) Error!void {
        switch (self.common.diagnostics_format) {
            .human => {
                const color = switch (self.common.color) {
                    .auto => self.process.stderr_color,
                    .always => true,
                    .never => false,
                };
                try report.writeHuman(self.process.stderr, color, findings, total, self.common.max_errors);
            },
            .json => {
                self.findings = findings;
                self.total = total;
            },
        }
    }

    fn fail(self: *Reporter, comptime format: []const u8, arguments: anytype) Error!void {
        switch (self.common.diagnostics_format) {
            .human => try self.process.stderr.print("cddl-zig: error: " ++ format ++ "\n", arguments),
            .json => if (self.failure == null) {
                self.failure = try std.fmt.allocPrint(self.arena, format, arguments);
            },
        }
    }

    fn finish(self: *Reporter, code: ExitCode) Error!ExitCode {
        if (self.common.diagnostics_format == .json) try report.writeJson(self.process.stderr, self.findings, self.total, self.failure);
        return code;
    }
};

fn generate(reporter: *Reporter, options: args.Generate) Error!ExitCode {
    const process = reporter.process;
    const to_stdout = std.mem.eql(u8, options.output, "-");
    if (!to_stdout and !std.mem.eql(u8, options.schema.input, "-")) {
        switch (sameFile(process, options.schema.input, options.output)) {
            .distinct => {},
            .same => {
                try reporter.fail("output '{f}' is the input file", .{Name{ .bytes = options.output }});
                return .usage;
            },
        }
    }
    const output = switch (try compile(reporter, options.schema, .{
        .runtime_import = options.runtime_import,
        .header = options.header,
    })) {
        .source => |source| source,
        .exit => |code| return code,
    };
    if (to_stdout) {
        try process.stdout.writeAll(output);
        return .ok;
    }

    const path = options.output;
    const state = (try compareFile(reporter, process.dir, path, path, output)) orelse return .io;
    if (options.check) {
        if (state == .same) return .ok;
        try reportStale(reporter, path, state);
        return .stale;
    }
    if (state == .same) return .ok;
    return if (try writeFile(reporter, process.dir, path, path, output)) .ok else .io;
}

const Identity = enum { same, distinct };

/// Whether an existing output path resolves to the input file, following
/// symlinks and `.`/`..` components. A missing or unresolvable output is
/// distinct; later steps report its errors. A hard link to the input is distinct:
/// the atomic rename replaces only that directory entry.
fn sameFile(process: Process, input: []const u8, output: []const u8) Identity {
    const io = process.io;
    const output_stat = process.dir.statFile(io, output, .{}) catch return .distinct;
    const input_stat = process.dir.statFile(io, input, .{}) catch return .distinct;
    if (output_stat.inode != input_stat.inode) return .distinct;

    var input_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var output_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Equal inodes without comparable canonical paths are treated as the same file.
    const input_length = process.dir.realPathFile(io, input, &input_buffer) catch return .same;
    const output_length = process.dir.realPathFile(io, output, &output_buffer) catch return .same;
    return if (std.mem.eql(u8, input_buffer[0..input_length], output_buffer[0..output_length])) .same else .distinct;
}

/// Paths in `runtime_sources.files` are relative to the output directory.
fn runtime(reporter: *Reporter, options: args.Runtime) Error!ExitCode {
    const process = reporter.process;
    const separator = if (std.mem.endsWith(u8, options.output, "/")) "" else "/";
    if (options.check) {
        const directory = process.dir.openDir(process.io, options.output, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                for (runtime_sources.files) |file| {
                    const display = try std.fmt.allocPrint(reporter.arena, "{s}{s}{s}", .{ options.output, separator, file.path });
                    try reportStale(reporter, display, .missing);
                }
                return .stale;
            },
            else => {
                try reporter.fail("cannot open directory '{f}': {t}", .{ Name{ .bytes = options.output }, err });
                return .io;
            },
        };
        defer directory.close(process.io);

        var stale = false;
        for (runtime_sources.files) |file| {
            const display = try std.fmt.allocPrint(reporter.arena, "{s}{s}{s}", .{ options.output, separator, file.path });
            const state = (try compareFile(reporter, directory, file.path, display, file.contents)) orelse return .io;
            if (state == .same) continue;
            try reportStale(reporter, display, state);
            stale = true;
        }
        return if (stale) .stale else .ok;
    }

    const directory = process.dir.createDirPathOpen(process.io, options.output, .{}) catch |err| {
        try reporter.fail("cannot create directory '{f}': {t}", .{ Name{ .bytes = options.output }, err });
        return .io;
    };
    defer directory.close(process.io);
    for (runtime_sources.files) |file| {
        const display = try std.fmt.allocPrint(reporter.arena, "{s}{s}{s}", .{ options.output, separator, file.path });
        const state = (try compareFile(reporter, directory, file.path, display, file.contents)) orelse return .io;
        if (state == .same) continue;
        if (!try writeFile(reporter, directory, file.path, display, file.contents)) return .io;
    }
    return .ok;
}

const Compiled = union(enum) {
    /// Generated Zig source.
    source: []u8,
    /// Diagnostics or errors were already reported.
    exit: ExitCode,
};

/// Runs the complete pipeline and reports every failure.
fn compile(reporter: *Reporter, schema: args.Check, generation: compiler.GenerateOptions) Error!Compiled {
    const arena = reporter.arena;
    const source = (try readInput(reporter, schema)) orelse return .{ .exit = .io };
    var diagnostics = compiler.Diagnostics.init(arena);
    diagnostics.limit = schema.common.max_errors;

    const tree = compiler.parse(arena, source, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSyntax => return .{ .exit = try reportDiagnostics(reporter, source, &diagnostics) },
    };
    const model = (try compiler.analyze(arena, &tree, &diagnostics, .{ .root = schema.root })) orelse
        return .{ .exit = try reportDiagnostics(reporter, source, &diagnostics) };

    var failed_node: ?compiler.model.NodeId = null;
    var options = generation;
    options.failed_node = &failed_node;
    const output = compiler.generate(arena, &model, options) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const failure = codes.fromGeneration(err) orelse {
            try reporter.fail("internal error: code generation failed: {t}", .{err});
            return .{ .exit = .internal };
        };
        const findings = try arena.alloc(report.Finding, 1);
        findings[0] = .{
            .code = failure.code,
            .message = failure.message,
            .location = nodeLocation(&model, source, failed_node),
        };
        try reporter.diagnostics(findings, 1);
        return .{ .exit = .schema };
    };
    return .{ .source = output };
}

const prelude_source: compiler.Source = .{ .name = "RFC 8610 prelude", .text = compiler.prelude.source };

fn nodeLocation(model: *const compiler.Model, source: compiler.Source, id: ?compiler.model.NodeId) ?report.Finding.Location {
    const node_id = id orelse return null;
    if (node_id >= model.nodes.len) return null;
    const origin = model.node(node_id).origin;
    return .{ .source = if (origin.prelude) prelude_source else source, .span = origin.span };
}

fn reportDiagnostics(reporter: *Reporter, source: compiler.Source, diagnostics: *const compiler.Diagnostics) Error!ExitCode {
    if (!diagnostics.hasErrors()) {
        try reporter.fail("internal error: schema rejected without a diagnostic", .{});
        return .internal;
    }
    const items = diagnostics.items.items;
    const findings = try reporter.arena.alloc(report.Finding, items.len);
    for (items, findings) |item, *finding| finding.* = .{
        .code = codes.Code.fromDiagnostic(item.code),
        .message = item.message,
        .location = .{ .source = if (item.source == .prelude) prelude_source else source, .span = item.span },
    };
    try reporter.diagnostics(findings, diagnostics.total);
    return .schema;
}

/// Returns null after reporting an I/O failure or an exceeded input limit.
fn readInput(reporter: *Reporter, schema: args.Check) Error!?compiler.Source {
    const process = reporter.process;
    const max = schema.common.max_input_bytes;
    // One extra byte distinguishes "exactly at the limit" from "over it".
    const limit: std.Io.Limit = .limited(std.math.add(usize, max, 1) catch std.math.maxInt(usize));
    if (std.mem.eql(u8, schema.input, "-")) {
        const name = schema.stdin_name;
        const text = process.stdin.allocRemaining(reporter.arena, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return inputTooLarge(reporter, name, max),
            error.ReadFailed => {
                try reporter.fail("cannot read '{f}'", .{Name{ .bytes = name }});
                return null;
            },
        };
        return .{ .name = name, .text = text };
    }

    const path = schema.input;
    const file = process.dir.openFile(process.io, path, .{}) catch |err| {
        try reporter.fail("cannot open '{f}': {t}", .{ Name{ .bytes = path }, err });
        return null;
    };
    defer file.close(process.io);
    const stat = file.stat(process.io) catch |err| {
        try reporter.fail("cannot stat '{f}': {t}", .{ Name{ .bytes = path }, err });
        return null;
    };
    if (stat.kind == .directory) {
        try reporter.fail("cannot read '{f}': IsDir", .{Name{ .bytes = path }});
        return null;
    }
    if (stat.kind == .file and stat.size > max) return inputTooLarge(reporter, path, max);

    var reader = file.reader(process.io, &.{});
    const text = reader.interface.allocRemaining(reporter.arena, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return inputTooLarge(reporter, path, max),
        error.ReadFailed => {
            try reporter.fail("cannot read '{f}': {t}", .{ Name{ .bytes = path }, reader.err orelse error.ReadFailed });
            return null;
        },
    };
    return .{ .name = path, .text = text };
}

fn inputTooLarge(reporter: *Reporter, name: []const u8, max: u32) Error!?compiler.Source {
    try reporter.fail("'{f}' exceeds --max-input-bytes {d}", .{ Name{ .bytes = name }, max });
    return null;
}

const FileState = enum { same, different, missing };

/// Returns null after reporting an I/O failure. Only regular files are opened,
/// so FIFOs and devices never block; at most expected.len + 1 bytes are read.
fn compareFile(
    reporter: *Reporter,
    dir: std.Io.Dir,
    sub_path: []const u8,
    display: []const u8,
    expected: []const u8,
) Error!?FileState {
    const io = reporter.process.io;
    const stat = dir.statFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => {
            try reporter.fail("cannot stat '{f}': {t}", .{ Name{ .bytes = display }, err });
            return null;
        },
    };
    if (stat.kind != .file) {
        try reporter.fail("'{f}' exists and is not a regular file ({t})", .{ Name{ .bytes = display }, stat.kind });
        return null;
    }
    if (stat.size != expected.len) return .different;

    const file = dir.openFile(io, sub_path, .{}) catch |err| {
        try reporter.fail("cannot open '{f}': {t}", .{ Name{ .bytes = display }, err });
        return null;
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const limit: std.Io.Limit = .limited(std.math.add(usize, expected.len, 1) catch std.math.maxInt(usize));
    const existing = reader.interface.allocRemaining(reporter.arena, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return .different,
        error.ReadFailed => {
            try reporter.fail("cannot read '{f}': {t}", .{ Name{ .bytes = display }, reader.err orelse error.ReadFailed });
            return null;
        },
    };
    return if (std.mem.eql(u8, existing, expected)) .same else .different;
}

fn reportStale(reporter: *Reporter, display: []const u8, state: FileState) Error!void {
    switch (state) {
        .same => {},
        .missing => try reporter.fail("'{f}' is missing", .{Name{ .bytes = display }}),
        .different => try reporter.fail("'{f}' differs from the expected output", .{Name{ .bytes = display }}),
    }
}

/// Replaces sub_path atomically. Returns false after reporting an I/O failure.
fn writeFile(reporter: *Reporter, dir: std.Io.Dir, sub_path: []const u8, display: []const u8, bytes: []const u8) Error!bool {
    const io = reporter.process.io;
    var atomic = dir.createFileAtomic(io, sub_path, .{ .replace = true }) catch |err| {
        try reporter.fail("cannot create '{f}': {t}", .{ Name{ .bytes = display }, err });
        return false;
    };
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, bytes) catch |err| {
        try reporter.fail("cannot write '{f}': {t}", .{ Name{ .bytes = display }, err });
        return false;
    };
    atomic.replace(io) catch |err| {
        try reporter.fail("cannot replace '{f}': {t}", .{ Name{ .bytes = display }, err });
        return false;
    };
    return true;
}

test "help, version, explain, and usage routing" {
    const Run = struct {
        fn expect(argv: []const []const u8, exit: ExitCode, out: []const u8, err: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var stdout: std.Io.Writer.Allocating = .init(arena.allocator());
            var stderr: std.Io.Writer.Allocating = .init(arena.allocator());
            var stdin: std.Io.Reader = .fixed("");
            const code = try run(arena.allocator(), argv, "1.2.3-test", .{
                .io = std.testing.io,
                .dir = std.Io.Dir.cwd(),
                .stdin = &stdin,
                .stdout = &stdout.writer,
                .stderr = &stderr.writer,
                .stderr_color = false,
            });
            try std.testing.expectEqual(exit, code);
            try std.testing.expectEqualStrings(out, stdout.written());
            try std.testing.expectEqualStrings(err, stderr.written());
        }
    };

    for ([_][]const []const u8{ &.{"version"}, &.{"--version"}, &.{"-V"} }) |argv| {
        try Run.expect(argv, .ok, "cddl-zig 1.2.3-test\n", "");
    }
    for ([_][]const []const u8{ &.{"help"}, &.{"--help"}, &.{"-h"} }) |argv| {
        try Run.expect(argv, .ok, help.overview, "");
    }
    inline for (std.meta.tags(args.Topic)) |topic| {
        try Run.expect(&.{ "help", @tagName(topic) }, .ok, help.text(topic), "");
        try Run.expect(&.{ @tagName(topic), "--unknown", "-h", "extra" }, .ok, help.text(topic), "");
        try std.testing.expect(std.mem.indexOf(u8, help.text(topic), "navailable") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, help.overview, "navailable") == null);

    try Run.expect(&.{}, .usage, "", "Usage: cddl-zig <command> [options]\n");
    try Run.expect(&.{"unknown\ncommand"}, .usage, "", "cddl-zig: error: unknown command; use 'cddl-zig help'\n");
    try Run.expect(&.{ "check", "a.cddl", "b.cddl" }, .usage, "", "cddl-zig: error: exactly one input file is accepted\n");
    try Run.expect(&.{ "explain", "E9999" }, .usage, "", "cddl-zig: error: unknown diagnostic code\n");

    for (std.enums.values(codes.Code)) |code| {
        var argument: [5]u8 = undefined;
        _ = try std.fmt.bufPrint(&argument, "{f}", .{code});
        var expected: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&expected, "{s} {s}: {s}\n", .{ &argument, @tagName(code), code.explanation() });
        try Run.expect(&.{ "explain", &argument }, .ok, line, "");
    }
}

test "check and generate validate schemas, report diagnostics, and write outputs" {
    const Harness = struct {
        arena: std.heap.ArenaAllocator,
        tmp: std.testing.TmpDir,

        const Outcome = struct { code: ExitCode, stdout: []const u8, stderr: []const u8 };

        fn exec(self: *@This(), argv: []const []const u8, input: []const u8, color: bool) !Outcome {
            const allocator = self.arena.allocator();
            var stdout: std.Io.Writer.Allocating = .init(allocator);
            var stderr: std.Io.Writer.Allocating = .init(allocator);
            var stdin: std.Io.Reader = .fixed(input);
            const code = try run(allocator, argv, "0.0.0-test", .{
                .io = std.testing.io,
                .dir = self.tmp.dir,
                .stdin = &stdin,
                .stdout = &stdout.writer,
                .stderr = &stderr.writer,
                .stderr_color = color,
            });
            return .{ .code = code, .stdout = stdout.written(), .stderr = stderr.written() };
        }

        fn put(self: *@This(), path: []const u8, data: []const u8) !void {
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
        }

        fn get(self: *@This(), path: []const u8) ![]u8 {
            return self.tmp.dir.readFileAlloc(std.testing.io, path, self.arena.allocator(), .unlimited);
        }
    };
    var h: Harness = .{ .arena = .init(std.testing.allocator), .tmp = std.testing.tmpDir(.{}) };
    defer h.arena.deinit();
    defer h.tmp.cleanup();
    const testing = std.testing;
    const valid = "packet = { id: uint, ? label: tstr }\n";
    try h.put("valid.cddl", valid);
    try h.put("bad.cddl", "root = [item]\nitem = missing\n");

    // A valid schema checks silently; json mode always emits one document.
    var outcome = try h.exec(&.{ "check", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.ok, outcome.code);
    try testing.expectEqualStrings("", outcome.stdout);
    try testing.expectEqualStrings("", outcome.stderr);
    outcome = try h.exec(&.{ "check", "--diagnostics=json", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.ok, outcome.code);
    try testing.expectEqualStrings("{\"diagnostics\":[],\"total\":0,\"omitted\":0,\"error\":null}\n", outcome.stderr);

    // Semantic diagnostics resolve to the file name, line, and column.
    outcome = try h.exec(&.{ "check", "bad.cddl" }, "", false);
    try testing.expectEqual(ExitCode.schema, outcome.code);
    try testing.expectEqualStrings("", outcome.stdout);
    try testing.expect(std.mem.startsWith(u8, outcome.stderr, "bad.cddl:2:8: error[E0301]: "));
    outcome = try h.exec(&.{ "check", "--color=always", "bad.cddl" }, "", false);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "\x1b[1;31merror[E0301]") != null);
    outcome = try h.exec(&.{ "check", "bad.cddl" }, "", true);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "\x1b[") != null);
    outcome = try h.exec(&.{ "check", "--color=never", "bad.cddl" }, "", true);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "\x1b[") == null);

    // Stdin uses --stdin-name for diagnostics.
    outcome = try h.exec(&.{ "check", "--stdin-name", "pipe.cddl", "-" }, "root = [item]\nitem = missing\n", false);
    try testing.expectEqual(ExitCode.schema, outcome.code);
    try testing.expect(std.mem.startsWith(u8, outcome.stderr, "pipe.cddl:2:8: error[E0301]: "));
    outcome = try h.exec(&.{ "check", "-" }, valid, false);
    try testing.expectEqual(ExitCode.ok, outcome.code);

    // --max-errors keeps a bounded prefix and counts every diagnostic.
    const Position = struct { offset: usize, line: usize, column: usize };
    const Document = struct {
        diagnostics: []const struct { code: []const u8, severity: []const u8, message: []const u8, source: ?[]const u8, start: ?Position, end: ?Position },
        total: usize,
        omitted: usize,
        @"error": ?[]const u8,
    };
    try h.put("many.cddl", "a = uint\n`\n`\n`\n");
    outcome = try h.exec(&.{ "check", "--diagnostics", "json", "--max-errors", "1", "many.cddl" }, "", false);
    try testing.expectEqual(ExitCode.schema, outcome.code);
    {
        const parsed = try std.json.parseFromSlice(Document, h.arena.allocator(), outcome.stderr, .{});
        try testing.expectEqual(@as(usize, 1), parsed.value.diagnostics.len);
        try testing.expect(parsed.value.total >= 3);
        try testing.expectEqual(parsed.value.total - 1, parsed.value.omitted);
        try testing.expectEqualStrings("many.cddl", parsed.value.diagnostics[0].source.?);
        try testing.expectEqual(@as(usize, 2), parsed.value.diagnostics[0].start.?.line);
    }
    outcome = try h.exec(&.{ "check", "--max-errors=0", "many.cddl" }, "", false);
    try testing.expect(std.mem.count(u8, outcome.stderr, "error[") >= 3);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "omitted") == null);

    // Input limits apply to files and stdin; exactly the limit is accepted.
    const limit = std.fmt.comptimePrint("--max-input-bytes={d}", .{valid.len});
    const below = std.fmt.comptimePrint("--max-input-bytes={d}", .{valid.len - 1});
    try testing.expectEqual(ExitCode.ok, (try h.exec(&.{ "check", limit, "valid.cddl" }, "", false)).code);
    try testing.expectEqual(ExitCode.ok, (try h.exec(&.{ "check", limit, "-" }, valid, false)).code);
    outcome = try h.exec(&.{ "check", below, "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.io, outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "--max-input-bytes") != null);
    try testing.expectEqual(ExitCode.io, (try h.exec(&.{ "check", below, "-" }, valid, false)).code);
    try testing.expectEqual(ExitCode.io, (try h.exec(&.{ "generate", "--max-input-bytes=0", "-" }, "x", false)).code);

    // Missing and directory inputs are I/O failures.
    try testing.expectEqual(ExitCode.io, (try h.exec(&.{ "check", "absent.cddl" }, "", false)).code);
    try h.tmp.dir.createDirPath(std.testing.io, "folder");
    try testing.expectEqual(ExitCode.io, (try h.exec(&.{ "check", "folder" }, "", false)).code);

    // JSON mode reports non-diagnostic failures inside its single document.
    outcome = try h.exec(&.{ "generate", "--diagnostics=json", "-o", "absent.zig", "absent.cddl" }, "", false);
    try testing.expectEqual(ExitCode.io, outcome.code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, outcome.stderr, "\n"));
    {
        const parsed = try std.json.parseFromSlice(Document, h.arena.allocator(), outcome.stderr, .{});
        try testing.expectEqual(@as(usize, 0), parsed.value.diagnostics.len);
        try testing.expect(std.mem.startsWith(u8, parsed.value.@"error".?, "cannot open 'absent.cddl': "));
    }
    outcome = try h.exec(&.{ "check", "--diagnostics=json", below, "-" }, valid, false);
    try testing.expectEqual(ExitCode.io, outcome.code);
    {
        const parsed = try std.json.parseFromSlice(Document, h.arena.allocator(), outcome.stderr, .{});
        try testing.expect(std.mem.indexOf(u8, parsed.value.@"error".?, "--max-input-bytes") != null);
    }

    // Generation to stdout produces parseable Zig that honors generator options.
    outcome = try h.exec(&.{ "generate", "--runtime-import=wire", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.ok, outcome.code);
    try testing.expectEqualStrings("", outcome.stderr);
    try testing.expect(std.mem.indexOf(u8, outcome.stdout, "@import(\"wire\")") != null);
    {
        const source = try h.arena.allocator().dupeZ(u8, outcome.stdout);
        var tree = try std.zig.Ast.parse(h.arena.allocator(), source, .zig);
        try testing.expectEqual(@as(usize, 0), tree.errors.len);
        tree.deinit(h.arena.allocator());
    }
    const generated = outcome.stdout;

    // File output matches stdout; --check compares without writing.
    outcome = try h.exec(&.{ "generate", "--runtime-import=wire", "--check", "-o", "out.zig", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.stale, outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "'out.zig' is missing") != null);
    try testing.expectError(error.FileNotFound, h.get("out.zig"));
    try testing.expectEqual(ExitCode.ok, (try h.exec(&.{ "generate", "--runtime-import=wire", "-o", "out.zig", "valid.cddl" }, "", false)).code);
    try testing.expectEqualStrings(generated, try h.get("out.zig"));
    try testing.expectEqual(ExitCode.ok, (try h.exec(&.{ "generate", "--runtime-import=wire", "--check", "-o", "out.zig", "valid.cddl" }, "", false)).code);
    try h.put("out.zig", "// edited\n");
    outcome = try h.exec(&.{ "generate", "--runtime-import=wire", "--check", "--output=out.zig", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.stale, outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "'out.zig' differs") != null);
    outcome = try h.exec(&.{ "generate", "--diagnostics=json", "--runtime-import=wire", "--check", "-o", "out.zig", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.stale, outcome.code);
    {
        const parsed = try std.json.parseFromSlice(Document, h.arena.allocator(), outcome.stderr, .{});
        try testing.expectEqual(@as(usize, 0), parsed.value.total);
        try testing.expectEqualStrings("'out.zig' differs from the expected output", parsed.value.@"error".?);
    }
    try testing.expectEqualStrings("// edited\n", try h.get("out.zig"));
    try testing.expectEqual(ExitCode.ok, (try h.exec(&.{ "generate", "--runtime-import=wire", "-o", "out.zig", "valid.cddl" }, "", false)).code);
    try testing.expectEqualStrings(generated, try h.get("out.zig"));

    // Output creation failures and non-regular output paths are I/O failures.
    try testing.expectEqual(ExitCode.io, (try h.exec(&.{ "generate", "-o", "missing/out.zig", "valid.cddl" }, "", false)).code);
    outcome = try h.exec(&.{ "generate", "--diagnostics=json", "-o", "missing/out.zig", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.io, outcome.code);
    try testing.expectEqualStrings("", outcome.stdout);
    {
        const parsed = try std.json.parseFromSlice(Document, h.arena.allocator(), outcome.stderr, .{});
        try testing.expectEqual(@as(usize, 0), parsed.value.diagnostics.len);
        try testing.expect(std.mem.startsWith(u8, parsed.value.@"error".?, "cannot create 'missing/out.zig': "));
    }
    outcome = try h.exec(&.{ "generate", "-o", "folder", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.io, outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "'folder' exists and is not a regular file") != null);
    try testing.expectEqual(ExitCode.io, (try h.exec(&.{ "generate", "--check", "-o", "folder", "valid.cddl" }, "", false)).code);

    // Output paths that resolve to the input are rejected and leave it intact.
    outcome = try h.exec(&.{ "generate", "-o", "./valid.cddl", "valid.cddl" }, "", false);
    try testing.expectEqual(ExitCode.usage, outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "is the input file") != null);
    try testing.expectEqual(ExitCode.usage, (try h.exec(&.{ "generate", "-o", "folder/../valid.cddl", "./valid.cddl" }, "", false)).code);
    if (@import("builtin").os.tag != .windows) {
        try h.tmp.dir.symLink(std.testing.io, "valid.cddl", "alias.cddl", .{});
        outcome = try h.exec(&.{ "generate", "--diagnostics=json", "-o", "alias.cddl", "valid.cddl" }, "", false);
        try testing.expectEqual(ExitCode.usage, outcome.code);
        const parsed = try std.json.parseFromSlice(Document, h.arena.allocator(), outcome.stderr, .{});
        try testing.expectEqualStrings("output 'alias.cddl' is the input file", parsed.value.@"error".?);
    }
    try testing.expectEqualStrings(valid, try h.get("valid.cddl"));

    // Schema errors and planning failures write nothing.
    try testing.expectEqual(ExitCode.schema, (try h.exec(&.{ "generate", "-o", "bad.zig", "bad.cddl" }, "", false)).code);
    try testing.expectError(error.FileNotFound, h.get("bad.zig"));
    try h.put("keys.cddl", "x = { * tstr => uint }\n");
    outcome = try h.exec(&.{ "generate", "--diagnostics=json", "-o", "keys.zig", "keys.cddl" }, "", false);
    try testing.expectEqual(ExitCode.schema, outcome.code);
    try testing.expectError(error.FileNotFound, h.get("keys.zig"));
    {
        const parsed = try std.json.parseFromSlice(Document, h.arena.allocator(), outcome.stderr, .{});
        try testing.expectEqual(@as(usize, 1), parsed.value.diagnostics.len);
        try testing.expectEqualStrings("E0505", parsed.value.diagnostics[0].code);
        try testing.expectEqualStrings("keys.cddl", parsed.value.diagnostics[0].source.?);
        try testing.expectEqual(@as(usize, 1), parsed.value.diagnostics[0].start.?.line);
    }
    outcome = try h.exec(&.{ "check", "keys.cddl" }, "", false);
    try testing.expectEqual(ExitCode.schema, outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "error[E0505]") != null);

    // --root selects the root rule; an unknown root is a schema error.
    try h.put("roots.cddl", "first = [uint]\nsecond = tstr\n");
    try testing.expectEqual(ExitCode.ok, (try h.exec(&.{ "check", "--root=second", "roots.cddl" }, "", false)).code);
    outcome = try h.exec(&.{ "check", "--root", "third", "roots.cddl" }, "", false);
    try testing.expectEqual(ExitCode.schema, outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.stderr, "error[E0301]") != null);

    // A conflicting redefinition of a prelude rule is reported at the prelude rule.
    outcome = try h.exec(&.{ "check", "--stdin-name=user.cddl", "-" }, "root = uint\nuint = text\n", false);
    try testing.expectEqual(ExitCode.schema, outcome.code);
    try testing.expect(std.mem.startsWith(u8, outcome.stderr, "RFC 8610 prelude:2:1: error[E0302]: "));
    outcome = try h.exec(&.{ "check", "--diagnostics=json", "-" }, "root = uint\nuint = text\n", false);
    {
        const parsed = try std.json.parseFromSlice(Document, h.arena.allocator(), outcome.stderr, .{});
        try testing.expectEqual(@as(usize, 1), parsed.value.diagnostics.len);
        try testing.expectEqualStrings("RFC 8610 prelude", parsed.value.diagnostics[0].source.?);
        try testing.expectEqual(Position{ .offset = 8, .line = 2, .column = 1 }, parsed.value.diagnostics[0].start.?);
        try testing.expect(parsed.value.@"error" == null);
    }
}

test "runtime writes and checks the complete embedded source set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const Run = struct {
        fn exec(allocator: std.mem.Allocator, dir: std.Io.Dir, argv: []const []const u8) !struct { ExitCode, []const u8 } {
            var stdout: std.Io.Writer.Allocating = .init(allocator);
            var stderr: std.Io.Writer.Allocating = .init(allocator);
            var stdin: std.Io.Reader = .fixed("");
            const code = try run(allocator, argv, "0.0.0-test", .{
                .io = std.testing.io,
                .dir = dir,
                .stdin = &stdin,
                .stdout = &stdout.writer,
                .stderr = &stderr.writer,
                .stderr_color = false,
            });
            try std.testing.expectEqualStrings("", stdout.written());
            return .{ code, stderr.written() };
        }
    };
    const allocator = arena.allocator();

    var code, var stderr = try Run.exec(allocator, tmp.dir, &.{ "runtime", "--check", "-o", "vendor/rt" });
    try std.testing.expectEqual(ExitCode.stale, code);
    try std.testing.expectEqual(runtime_sources.files.len, std.mem.count(u8, stderr, "is missing"));

    code, stderr = try Run.exec(allocator, tmp.dir, &.{ "runtime", "-o", "vendor/rt" });
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr);
    for (runtime_sources.files) |file| {
        const path = try std.fmt.allocPrint(allocator, "vendor/rt/{s}", .{file.path});
        try std.testing.expectEqualStrings(file.contents, try tmp.dir.readFileAlloc(io, path, allocator, .unlimited));
    }
    code, _ = try Run.exec(allocator, tmp.dir, &.{ "runtime", "--check", "--output=vendor/rt/" });
    try std.testing.expectEqual(ExitCode.ok, code);

    const changed = runtime_sources.files[1].path;
    const removed = runtime_sources.files[2].path;
    const directory = try tmp.dir.openDir(io, "vendor/rt", .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = changed, .data = "// edited\n" });
    try directory.deleteFile(io, removed);
    code, stderr = try Run.exec(allocator, tmp.dir, &.{ "runtime", "--check", "-o", "vendor/rt" });
    try std.testing.expectEqual(ExitCode.stale, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr, try std.fmt.allocPrint(allocator, "'vendor/rt/{s}' differs", .{changed})) != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, try std.fmt.allocPrint(allocator, "'vendor/rt/{s}' is missing", .{removed})) != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, stderr, "cddl-zig: error: "));
    try std.testing.expectEqualStrings("// edited\n", try directory.readFileAlloc(io, changed, allocator, .unlimited));

    code, _ = try Run.exec(allocator, tmp.dir, &.{ "runtime", "-o", "vendor/rt" });
    try std.testing.expectEqual(ExitCode.ok, code);
    code, _ = try Run.exec(allocator, tmp.dir, &.{ "runtime", "--check", "-o", "vendor/rt" });
    try std.testing.expectEqual(ExitCode.ok, code);

    try tmp.dir.writeFile(io, .{ .sub_path = "plain", .data = "" });
    code, _ = try Run.exec(allocator, tmp.dir, &.{ "runtime", "-o", "plain" });
    try std.testing.expectEqual(ExitCode.io, code);
}

test "output capacity failures propagate instead of reporting success" {
    var empty_buffer: [0]u8 = .{};
    var stderr_buffer: [128]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&empty_buffer);
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var stdin: std.Io.Reader = .fixed("");
    try std.testing.expectError(error.WriteFailed, run(std.testing.allocator, &.{"version"}, "1.0.0", .{
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
        .stdin = &stdin,
        .stdout = &stdout,
        .stderr = &stderr,
        .stderr_color = false,
    }));
}

test "allocation failures have their own exit code and exact message" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var stdout_buffer: [64]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var stdin: std.Io.Reader = .fixed("a = uint\n");
    const code = try run(failing.allocator(), &.{ "check", "-" }, "1.0.0", .{
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
        .stdin = &stdin,
        .stdout = &stdout,
        .stderr = &stderr,
        .stderr_color = false,
    });
    try std.testing.expectEqual(ExitCode.oom, code);
    try std.testing.expectEqualStrings("", stdout.buffered());
    try std.testing.expectEqualStrings("cddl-zig: error: out of memory\n", stderr.buffered());

    _ = stderr.consumeAll();
    stdin = .fixed("a = uint\n");
    failing = .init(std.testing.allocator, .{ .fail_index = 0 });
    const json_code = try run(failing.allocator(), &.{ "check", "--diagnostics=json", "-" }, "1.0.0", .{
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
        .stdin = &stdin,
        .stdout = &stdout,
        .stderr = &stderr,
        .stderr_color = false,
    });
    try std.testing.expectEqual(ExitCode.oom, json_code);
    try std.testing.expectEqualStrings("{\"diagnostics\":[],\"total\":0,\"omitted\":0,\"error\":\"out of memory\"}\n", stderr.buffered());
}

test {
    _ = args;
    _ = help;
    _ = codes;
    _ = report;
}
