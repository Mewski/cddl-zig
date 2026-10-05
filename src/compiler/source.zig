const std = @import("std");

/// Half-open byte offsets into a Source.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn merge(a: Span, b: Span) Span {
        return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }
};

pub const Source = struct {
    name: []const u8,
    text: []const u8,

    pub const Location = struct { line: usize, column: usize };

    pub fn slice(self: Source, span: Span) []const u8 {
        return self.text[span.start..span.end];
    }

    /// Lines and byte columns are one-based, including the EOF position.
    pub fn location(self: Source, offset: usize) Location {
        var result: Location = .{ .line = 1, .column = 1 };
        for (self.text[0..@min(offset, self.text.len)]) |byte| {
            if (byte == '\n') {
                result.line += 1;
                result.column = 1;
            } else result.column += 1;
        }
        return result;
    }
};

test "source locations use byte offsets" {
    const source: Source = .{ .name = "test", .text = "a\r\nb" };
    try std.testing.expectEqual(Source.Location{ .line = 2, .column = 1 }, source.location(3));
    try std.testing.expectEqualStrings("b", source.slice(.{ .start = 3, .end = 4 }));
}
