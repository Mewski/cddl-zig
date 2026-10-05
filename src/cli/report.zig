const std = @import("std");
const compiler = @import("cddl").compiler;
const codes = @import("codes.zig");

pub const Finding = struct {
    code: codes.Code,
    message: []const u8,
    /// Null when the failure has no source position.
    location: ?Location,

    pub const Location = struct { source: compiler.Source, span: compiler.Span };
};

/// `total` counts every reported diagnostic, including those omitted by the limit.
pub fn writeHuman(writer: *std.Io.Writer, color: bool, findings: []const Finding, total: usize, max_errors: u32) std.Io.Writer.Error!void {
    var locator: Locator = .{};
    for (findings) |finding| try human(writer, color, &locator, finding);
    const omitted = total -| findings.len;
    if (omitted != 0) try writer.print("cddl-zig: note: {d} more diagnostics omitted by --max-errors {d}\n", .{ omitted, max_errors });
}

/// Writes the single JSON document of a schema command. `failure` is the
/// non-diagnostic error that ended the command, if any.
pub fn writeJson(writer: *std.Io.Writer, findings: []const Finding, total: usize, failure: ?[]const u8) std.Io.Writer.Error!void {
    var locator: Locator = .{};
    try writer.writeAll("{\"diagnostics\":[");
    for (findings, 0..) |finding, index| {
        if (index != 0) try writer.writeByte(',');
        try json(writer, &locator, finding);
    }
    try writer.print("],\"total\":{d},\"omitted\":{d},\"error\":", .{ total, total -| findings.len });
    if (failure) |message| try jsonString(writer, message) else try writer.writeAll("null");
    try writer.writeAll("}\n");
}

fn human(writer: *std.Io.Writer, color: bool, locator: *Locator, finding: Finding) std.Io.Writer.Error!void {
    const bold = if (color) "\x1b[1m" else "";
    const red = if (color) "\x1b[1;31m" else "";
    const reset = if (color) "\x1b[0m" else "";
    try writer.writeAll(bold);
    if (finding.location) |location| {
        const start = locator.locate(location.source, location.span.start);
        try writer.print("{f}:{d}:{d}: ", .{ Name{ .bytes = location.source.name }, start.line, start.column });
    } else {
        try writer.writeAll("cddl-zig: ");
    }
    try writer.print("{s}{s}error[{f}]:{s} {f}\n", .{ reset, red, finding.code, reset, Name{ .bytes = finding.message } });
}

fn json(writer: *std.Io.Writer, locator: *Locator, finding: Finding) std.Io.Writer.Error!void {
    try writer.print("{{\"code\":\"{f}\",\"severity\":\"error\",\"message\":", .{finding.code});
    try jsonString(writer, finding.message);
    const location = finding.location orelse return writer.writeAll(",\"source\":null,\"start\":null,\"end\":null}");
    try writer.writeAll(",\"source\":");
    try jsonString(writer, location.source.name);
    const start = locator.locate(location.source, location.span.start);
    var end_locator = locator.*;
    const end = end_locator.locate(location.source, @max(location.span.start, location.span.end));
    try writer.print(",\"start\":{{\"offset\":{d},\"line\":{d},\"column\":{d}}}", .{ start.offset, start.line, start.column });
    try writer.print(",\"end\":{{\"offset\":{d},\"line\":{d},\"column\":{d}}}}}", .{ end.offset, end.line, end.column });
}

/// Incremental byte-offset to one-based line/column conversion with the same
/// rules as `Source.location`. Offsets past the text clamp to its end.
const Locator = struct {
    text: []const u8 = "",
    position: Position = .{ .offset = 0, .line = 1, .column = 1 },

    const Position = struct { offset: usize, line: usize, column: usize };

    fn locate(self: *Locator, source: compiler.Source, offset: usize) Position {
        const target = @min(offset, source.text.len);
        if (self.text.ptr != source.text.ptr or self.text.len != source.text.len or target < self.position.offset) {
            self.text = source.text;
            self.position = .{ .offset = 0, .line = 1, .column = 1 };
        }
        for (source.text[self.position.offset..target]) |byte| {
            if (byte == '\n') {
                self.position.line += 1;
                self.position.column = 1;
            } else self.position.column += 1;
        }
        self.position.offset = target;
        return self.position;
    }
};

/// Writes a JSON string. Invalid UTF-8 bytes become U+FFFD.
fn jsonString(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0...8, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\u{x:0>4}", .{byte}),
                else => try writer.writeByte(byte),
            }
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (length != 0 and length <= bytes.len - index and std.unicode.utf8ValidateSlice(bytes[index..][0..length])) {
            try writer.writeAll(bytes[index..][0..length]);
            index += length;
        } else {
            try writer.writeAll("\\ufffd");
            index += 1;
        }
    }
    try writer.writeByte('"');
}

/// Terminal-safe display of names and paths: control bytes become `\xNN`.
pub const Name = struct {
    bytes: []const u8,

    pub fn format(self: Name, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.bytes) |byte| {
            if (byte < 0x20 or byte == 0x7f) {
                try writer.print("\\x{x:0>2}", .{byte});
            } else try writer.writeByte(byte);
        }
    }
};

test "human diagnostics resolve spans to one-based lines and columns" {
    const source: compiler.Source = .{ .name = "a.cddl", .text = "a = uint\nb = c\n" };
    const findings = [_]Finding{
        .{ .code = .unknown_name, .message = "reference names an unknown rule or parameter", .location = .{ .source = source, .span = .{ .start = 13, .end = 14 } } },
        .{ .code = .invalid_schema, .message = "first", .location = .{ .source = source, .span = .{ .start = 0, .end = 1 } } },
        .{ .code = .generation_overflow, .message = "no position", .location = null },
    };
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeHuman(&writer, false, &findings, 5, 3);
    try std.testing.expectEqualStrings(
        "a.cddl:2:5: error[E0301]: reference names an unknown rule or parameter\n" ++
            "a.cddl:1:1: error[E0401]: first\n" ++
            "cddl-zig: error[E0601]: no position\n" ++
            "cddl-zig: note: 2 more diagnostics omitted by --max-errors 3\n",
        writer.buffered(),
    );
}

test "color wraps only the location and severity" {
    const source: compiler.Source = .{ .name = "x", .text = "" };
    const finding: Finding = .{ .code = .unknown_name, .message = "m", .location = .{ .source = source, .span = .{ .start = 0, .end = 0 } } };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeHuman(&writer, true, &.{finding}, 1, 50);
    try std.testing.expectEqualStrings("\x1b[1mx:1:1: \x1b[0m\x1b[1;31merror[E0301]:\x1b[0m m\n", writer.buffered());
}

test "json diagnostics are one valid document with exact positions" {
    const source: compiler.Source = .{ .name = "dir/\"q\"\x01\xff.cddl", .text = "a = [\n  uint,\n" };
    const findings = [_]Finding{
        .{ .code = .expected_token, .message = "expected \"]\"", .location = .{ .source = source, .span = .{ .start = 9, .end = 99 } } },
        .{ .code = .generation_overflow, .message = "none", .location = null },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeJson(&output.writer, &findings, 2, null);
    const text = output.written();
    try std.testing.expect(std.mem.endsWith(u8, text, "}\n"));

    const Position = struct { offset: usize, line: usize, column: usize };
    const Document = struct {
        diagnostics: []const struct {
            code: []const u8,
            severity: []const u8,
            message: []const u8,
            source: ?[]const u8,
            start: ?Position,
            end: ?Position,
        },
        total: usize,
        omitted: usize,
        @"error": ?[]const u8,
    };
    const parsed = try std.json.parseFromSlice(Document, std.testing.allocator, text, .{});
    defer parsed.deinit();
    const items = parsed.value.diagnostics;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("E0202", items[0].code);
    try std.testing.expectEqualStrings("error", items[0].severity);
    try std.testing.expectEqualStrings("expected \"]\"", items[0].message);
    try std.testing.expectEqualStrings("dir/\"q\"\x01\u{fffd}.cddl", items[0].source.?);
    try std.testing.expectEqual(Position{ .offset = 9, .line = 2, .column = 4 }, items[0].start.?);
    try std.testing.expectEqual(Position{ .offset = 14, .line = 3, .column = 1 }, items[0].end.?);
    try std.testing.expect(items[1].source == null and items[1].start == null and items[1].end == null);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.total);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.omitted);
    try std.testing.expect(parsed.value.@"error" == null);

    output.clearRetainingCapacity();
    try writeJson(&output.writer, &.{}, 0, "cannot open 'a\"b': FileNotFound");
    const failed = try std.json.parseFromSlice(Document, std.testing.allocator, output.written(), .{});
    defer failed.deinit();
    try std.testing.expectEqual(@as(usize, 0), failed.value.diagnostics.len);
    try std.testing.expectEqualStrings("cannot open 'a\"b': FileNotFound", failed.value.@"error".?);
}

test "locator matches Source.location for arbitrary offsets" {
    const source: compiler.Source = .{ .name = "s", .text = "ab\n\ncd\r\nef" };
    var locator: Locator = .{};
    for ([_]usize{ 0, 5, 2, 10, 3, 99, 1 }) |offset| {
        const expected = source.location(offset);
        const actual = locator.locate(source, offset);
        try std.testing.expectEqual(expected.line, actual.line);
        try std.testing.expectEqual(expected.column, actual.column);
    }
}

test "names escape control bytes" {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{Name{ .bytes = "a\nb\x1b" }});
    try std.testing.expectEqualStrings("a\\x0ab\\x1b", text);
}
