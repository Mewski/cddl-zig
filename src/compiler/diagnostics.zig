const std = @import("std");
const Span = @import("source.zig").Span;

pub const Code = enum {
    invalid_character,
    invalid_utf8,
    unterminated_string,
    invalid_escape,
    invalid_number,
    integer_overflow,
    invalid_byte_string,
    unexpected_token,
    expected_token,
    invalid_occurrence,
    nesting_limit,
    node_limit,
    unsupported_extension,
    unknown_name,
    duplicate_rule,
    invalid_schema,
};

pub const SourceKind = enum { input, prelude };

pub const Diagnostic = struct {
    code: Code,
    span: Span,
    message: []const u8,
    source: SourceKind = .input,
    related: ?Span = null,
};

/// Messages are borrowed; the front end uses static messages exclusively.
pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    limit: usize = 50,
    total: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Diagnostics, code: Code, span: Span, message: []const u8) !void {
        return self.addFrom(code, span, message, .input);
    }

    pub fn addFrom(self: *Diagnostics, code: Code, span: Span, message: []const u8, source: SourceKind) !void {
        self.total +|= 1;
        if (self.limit == 0 or self.items.items.len < self.limit) {
            try self.items.append(self.allocator, .{ .code = code, .span = span, .message = message, .source = source });
        }
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        return self.total != 0;
    }
};

test "diagnostics retain bounded detail without hiding errors" {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    diagnostics.limit = 1;
    try diagnostics.add(.unexpected_token, .{ .start = 0, .end = 1 }, "unexpected token");
    try diagnostics.add(.unexpected_token, .{ .start = 1, .end = 2 }, "unexpected token");
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.total);
}

test "zero diagnostic limit retains every detail" {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    diagnostics.limit = 0;
    try diagnostics.add(.unexpected_token, .{ .start = 0, .end = 1 }, "first");
    try diagnostics.add(.unexpected_token, .{ .start = 1, .end = 2 }, "second");

    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.total);
}
