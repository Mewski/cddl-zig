const std = @import("std");
const Source = @import("source.zig").Source;
const Span = @import("source.zig").Span;
const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const Kind = enum {
    eof,
    invalid,
    identifier,
    number,
    text,
    bytes,
    equal,
    type_extend,
    group_extend,
    slash,
    group_slash,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    less,
    greater,
    colon,
    comma,
    arrow,
    cut,
    star,
    plus,
    question,
    tilde,
    ampersand,
    hash,
    dot,
    range_inclusive,
    range_exclusive,
};
pub const Token = struct { kind: Kind, span: Span };

pub const Lexer = struct {
    source: Source,
    diagnostics: *Diagnostics,
    offset: usize = 0,
    after_hash: bool = false,

    pub fn init(source: Source, diagnostics: *Diagnostics) Lexer {
        return .{ .source = source, .diagnostics = diagnostics };
    }

    fn token(self: *const Lexer, kind: Kind, start: usize) Token {
        return .{ .kind = kind, .span = .{ .start = start, .end = self.offset } };
    }

    fn report(self: *Lexer, code: @import("diagnostics.zig").Code, start: usize, message: []const u8) !void {
        try self.diagnostics.add(code, .{ .start = start, .end = self.offset }, message);
    }

    fn match(self: *Lexer, byte: u8) bool {
        if (self.offset < self.source.text.len and self.source.text[self.offset] == byte) {
            self.offset += 1;
            return true;
        }
        return false;
    }

    fn nonAscii(self: *Lexer) !bool {
        const start = self.offset;
        const text = self.source.text;
        const length = std.unicode.utf8ByteSequenceLength(text[start]) catch {
            self.offset += 1;
            try self.report(.invalid_utf8, start, "invalid UTF-8 sequence");
            return false;
        };
        if (text.len - start < length) {
            self.offset = text.len;
            try self.report(.invalid_utf8, start, "truncated UTF-8 sequence");
            return false;
        }
        self.offset += length;
        const scalar = std.unicode.utf8Decode(text[start..self.offset]) catch {
            try self.report(.invalid_utf8, start, "invalid UTF-8 sequence");
            return false;
        };
        if (scalar < 0xa0 or scalar > 0x10fffd) {
            try self.report(.invalid_character, start, "character is excluded by RFC 9682 NONASCII");
            return false;
        }
        return true;
    }

    fn whitespace(self: *Lexer) !void {
        const text = self.source.text;
        while (self.offset < text.len) {
            switch (text[self.offset]) {
                ' ', '\n' => self.offset += 1,
                '\r' => {
                    const start = self.offset;
                    self.offset += 1;
                    if (!self.match('\n')) try self.report(.invalid_character, start, "carriage return must be followed by line feed");
                },
                ';' => {
                    const comment_start = self.offset;
                    self.offset += 1;
                    while (self.offset < text.len and text[self.offset] != '\n' and text[self.offset] != '\r') {
                        const start = self.offset;
                        const byte = text[start];
                        if (byte >= 0x80) {
                            _ = try self.nonAscii();
                        } else {
                            self.offset += 1;
                            if (byte < 0x20 or byte == 0x7f) try self.report(.invalid_character, start, "control character is not allowed in a comment");
                        }
                    }
                    if (self.offset == text.len) try self.report(.expected_token, self.offset, "comment must end with a line feed");
                    if (isModuleDirective(text, comment_start)) try self.report(.unsupported_extension, comment_start, "CDDL module directives (;# import, ;# include) are not supported");
                },
                else => return,
            }
        }
    }

    fn string(self: *Lexer, start: usize, quote: u8) !Token {
        const text = self.source.text;
        while (self.offset < text.len) {
            const at = self.offset;
            const byte = text[at];
            if (byte == quote) {
                self.offset += 1;
                return self.token(if (quote == '"') .text else .bytes, start);
            }
            if (byte == '\\') {
                self.offset += 1;
                if (self.offset < text.len and text[self.offset] != '\n' and text[self.offset] != '\r') {
                    self.offset += 1;
                    continue;
                }
            } else if (byte >= 0x80) {
                _ = try self.nonAscii();
                continue;
            } else if (quote == '\'' and byte == '\n') {
                self.offset += 1;
                continue;
            } else if (quote == '\'' and byte == '\r' and self.offset + 1 < text.len and text[self.offset + 1] == '\n') {
                self.offset += 2;
                continue;
            } else if (byte >= 0x20 and byte <= 0x7e) {
                self.offset += 1;
                continue;
            } else if (byte != '\n' and byte != '\r') {
                self.offset += 1;
                try self.report(.invalid_character, at, "control character is not allowed in a string");
                continue;
            }
            try self.report(.unterminated_string, start, "unterminated string literal");
            return self.token(.invalid, start);
        }
        try self.report(.unterminated_string, start, "unterminated string literal");
        return self.token(.invalid, start);
    }

    fn digits(self: *Lexer, base: u8) void {
        const text = self.source.text;
        while (self.offset < text.len) {
            const digit = std.fmt.charToDigit(text[self.offset], base) catch return;
            _ = digit;
            self.offset += 1;
        }
    }

    fn number(self: *Lexer, start: usize) Token {
        const text = self.source.text;
        self.offset = start;
        _ = self.match('-');
        var base: u8 = 10;
        if (self.offset + 1 < text.len and text[self.offset] == '0') {
            const prefix = std.ascii.toLower(text[self.offset + 1]);
            if (prefix == 'x' or prefix == 'b') {
                base = if (prefix == 'x') 16 else 2;
                self.offset += 2;
            }
        }
        self.digits(base);
        var exponent: u8 = if (base == 16) 'p' else 'e';
        if (self.offset + 1 < text.len and text[self.offset] == '.' and (if (base == 16) std.ascii.isHex(text[self.offset + 1]) else std.ascii.isDigit(text[self.offset + 1]))) {
            self.offset += 1;
            const fraction_start = self.offset;
            self.digits(if (base == 16) 16 else 10);
            if (base == 16 and (self.offset == text.len or std.ascii.toLower(text[self.offset]) != 'p')) {
                self.offset = fraction_start;
                self.digits(10);
                exponent = 'e';
            }
        } else if (base == 16 and self.offset > start and self.offset < text.len and (text[self.offset] == '+' or text[self.offset] == '-') and std.ascii.toLower(text[self.offset - 1]) == 'e') {
            self.offset -= 1;
            exponent = 'e';
        }
        if (self.offset < text.len and std.ascii.toLower(text[self.offset]) == exponent) {
            self.offset += 1;
            if (!self.match('+')) _ = self.match('-');
            self.digits(10);
        }
        return self.token(.number, start);
    }

    pub fn next(self: *Lexer) std.mem.Allocator.Error!Token {
        const before_space = self.offset;
        try self.whitespace();
        const start = self.offset;
        const text = self.source.text;
        const head_digit = self.after_hash and before_space == start;
        self.after_hash = false;
        if (start == text.len) return self.token(.eof, start);
        const byte = text[start];
        self.offset += 1;
        if (head_digit and std.ascii.isDigit(byte)) return self.token(.number, start);
        if (ealpha(byte)) {
            while (self.offset < text.len) {
                if (ealpha(text[self.offset]) or std.ascii.isDigit(text[self.offset])) {
                    self.offset += 1;
                } else if (text[self.offset] == '-' or text[self.offset] == '.') {
                    var end = self.offset;
                    while (end < text.len and (text[end] == '-' or text[end] == '.')) : (end += 1) {}
                    if (end < text.len and (ealpha(text[end]) or std.ascii.isDigit(text[end]))) self.offset = end + 1 else break;
                } else break;
            }
            const word = text[start..self.offset];
            if ((std.ascii.eqlIgnoreCase(word, "h") or std.ascii.eqlIgnoreCase(word, "b64")) and self.match('\'')) return self.string(start, '\'');
            return self.token(.identifier, start);
        }
        if (std.ascii.isDigit(byte) or (byte == '-' and self.offset < text.len and std.ascii.isDigit(text[self.offset]))) return self.number(start);
        const kind: Kind = switch (byte) {
            '"', '\'' => return self.string(start, byte),
            '=' => if (self.match('>')) .arrow else .equal,
            '/' => if (self.match('/')) (if (self.match('=')) .group_extend else .group_slash) else if (self.match('=')) .type_extend else .slash,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            '<' => .less,
            '>' => .greater,
            ':' => .colon,
            ',' => .comma,
            '^' => .cut,
            '*' => .star,
            '+' => .plus,
            '?' => .question,
            '~' => .tilde,
            '&' => .ampersand,
            '#' => blk: {
                self.after_hash = true;
                break :blk .hash;
            },
            '.' => if (self.match('.')) (if (self.match('.')) .range_exclusive else .range_inclusive) else .dot,
            else => .invalid,
        };
        if (kind == .invalid) try self.report(.invalid_character, start, "character is not part of CDDL syntax");
        return self.token(kind, start);
    }
};

fn ealpha(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '@' or byte == '_' or byte == '$';
}

/// draft-ietf-cbor-cddl-modules directive: `;#` in column 1, one or more
/// spaces, then `import` or `include` followed by a space.
fn isModuleDirective(text: []const u8, start: usize) bool {
    if (start != 0 and text[start - 1] != '\n') return false;
    if (!std.mem.startsWith(u8, text[start..], ";#")) return false;
    const after_hash = start + 2;
    const keyword = std.mem.indexOfNonePos(u8, text, after_hash, " ") orelse return false;
    if (keyword == after_hash) return false;
    const rest = text[keyword..];
    return std.mem.startsWith(u8, rest, "import ") or std.mem.startsWith(u8, rest, "include ");
}

test "RFC tokens distinguish heads, augmentation and ranges" {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var lexer = Lexer.init(.{ .name = "test", .text = "$$x //= #6.24(uint) 0..1 0x1.fp+2 b64'YQ=='" }, &diagnostics);
    const expected = [_]Kind{ .identifier, .group_extend, .hash, .number, .dot, .number, .lparen, .identifier, .rparen, .number, .range_inclusive, .number, .number, .bytes, .eof };
    for (expected) |kind| try std.testing.expectEqual(kind, (try lexer.next()).kind);
    try std.testing.expect(!diagnostics.hasErrors());
}

test "column-1 module directives are unsupported extensions" {
    const Case = struct { text: []const u8, directive: []const u8 };
    const cases = [_]Case{
        .{ .text = ";# import rfc9052\na = int\n", .directive = ";# import rfc9052" },
        .{ .text = "a = int\r\n;#   include rfc9165 as x\r\n", .directive = ";#   include rfc9165 as x" },
    };
    for (cases) |case| {
        var diagnostics = Diagnostics.init(std.testing.allocator);
        defer diagnostics.deinit();
        var lexer = Lexer.init(.{ .name = "test", .text = case.text }, &diagnostics);
        const expected = [_]Kind{ .identifier, .equal, .identifier, .eof };
        for (expected) |kind| try std.testing.expectEqual(kind, (try lexer.next()).kind);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.items.items.len);
        const diagnostic = diagnostics.items.items[0];
        try std.testing.expect(diagnostic.code == .unsupported_extension);
        try std.testing.expectEqualStrings(case.directive, case.text[diagnostic.span.start..diagnostic.span.end]);
    }
}

test "other comments, including directive look-alikes, stay comments" {
    const text =
        \\; plain comment
        \\;####
        \\;#
        \\;# imports are described elsewhere
        \\;#import x
        \\;# include
        \\ ;# import x
        \\a = int ;# include y
        \\
    ;
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var lexer = Lexer.init(.{ .name = "test", .text = text }, &diagnostics);
    const expected = [_]Kind{ .identifier, .equal, .identifier, .eof };
    for (expected) |kind| try std.testing.expectEqual(kind, (try lexer.next()).kind);
    try std.testing.expect(!diagnostics.hasErrors());
}
