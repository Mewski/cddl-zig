const std = @import("std");
const Literal = @import("ast.zig").Literal;
pub const Error = error{ InvalidNumber, IntegerOverflow, InvalidEscape, InvalidByteString, OutOfMemory };

pub fn unsigned(text: []const u8) Error!u64 {
    const parsed = try magnitude(text);
    if (parsed > std.math.maxInt(u64)) return error.IntegerOverflow;
    return @intCast(parsed);
}

fn magnitude(text: []const u8) Error!u65 {
    if (text.len == 0) return error.InvalidNumber;
    var digits = text;
    var base: u8 = 10;
    if (text.len >= 2 and text[0] == '0') {
        switch (std.ascii.toLower(text[1])) {
            'x' => {
                base = 16;
                digits = text[2..];
            },
            'b' => {
                base = 2;
                digits = text[2..];
            },
            else => return error.InvalidNumber,
        }
    }
    if (digits.len == 0) return error.InvalidNumber;
    var value: u65 = 0;
    for (digits) |byte| {
        const digit = std.fmt.charToDigit(byte, base) catch return error.InvalidNumber;
        value = std.math.mul(u65, value, base) catch return error.IntegerOverflow;
        value = std.math.add(u65, value, digit) catch return error.IntegerOverflow;
    }
    return value;
}

pub fn number(allocator: std.mem.Allocator, text: []const u8) Error!Literal {
    const negative = text.len != 0 and text[0] == '-';
    const body = text[@intFromBool(negative)..];
    if (body.len == 0) return error.InvalidNumber;
    const hexadecimal = body.len > 2 and body[0] == '0' and std.ascii.toLower(body[1]) == 'x';
    const binary = body.len > 2 and body[0] == '0' and std.ascii.toLower(body[1]) == 'b';
    var floating = false;
    var hexfloat = false;
    for (body) |byte| {
        if (std.ascii.toLower(byte) == 'p') hexfloat = true;
        if (byte == '.' or byte == '+' or byte == '-' or std.ascii.toLower(byte) == 'p' or (!hexadecimal and std.ascii.toLower(byte) == 'e')) floating = true;
    }
    if (!floating) {
        const value = try magnitude(body);
        if (negative) {
            if (value > (@as(u65, 1) << 64)) return error.IntegerOverflow;
            if (value == 0) return .{ .unsigned = 0 };
            return .{ .negative = -@as(i65, @intCast(value - 1)) - 1 };
        }
        if (value > std.math.maxInt(u64)) return error.IntegerOverflow;
        return .{ .unsigned = @intCast(value) };
    }
    const normalized: ?[]const u8 = if ((hexadecimal and !hexfloat) or binary) try decimalForm(allocator, text) else null;
    defer if (normalized) |owned| allocator.free(owned);
    const parse_text = normalized orelse text;
    try validateFloat(parse_text[@intFromBool(negative)..], hexadecimal and hexfloat);
    const value = std.fmt.parseFloat(f64, parse_text) catch return error.InvalidNumber;
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    return .{ .float = .{ .lexeme = text, .value = value } };
}

fn decimalForm(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    const negative = text[0] == '-';
    const prefix: usize = @intFromBool(negative);
    const base: u8 = if (std.ascii.toLower(text[prefix + 1]) == 'x') 16 else 2;
    const first = prefix + 2;
    var end = first;
    while (end < text.len) : (end += 1) {
        _ = std.fmt.charToDigit(text[end], base) catch break;
    }
    if (base == 16 and end > first and end < text.len and (text[end] == '+' or text[end] == '-') and std.ascii.toLower(text[end - 1]) == 'e') end -= 1;
    if (end == first) return error.InvalidNumber;
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(allocator);
    try digits.append(allocator, 0);
    for (text[first..end]) |byte| {
        var carry: u16 = std.fmt.charToDigit(byte, base) catch return error.InvalidNumber;
        for (digits.items) |*digit| {
            const product = @as(u16, digit.*) * base + carry;
            digit.* = @intCast(product % 10);
            carry = product / 10;
        }
        while (carry != 0) {
            try digits.append(allocator, @intCast(carry % 10));
            carry /= 10;
        }
    }
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    if (negative) try result.append(allocator, '-');
    var remaining = digits.items.len;
    while (remaining != 0) {
        remaining -= 1;
        try result.append(allocator, '0' + digits.items[remaining]);
    }
    try result.appendSlice(allocator, text[end..]);
    return result.toOwnedSlice(allocator);
}

fn validateFloat(body: []const u8, hexadecimal: bool) Error!void {
    var index: usize = if (hexadecimal) 2 else 0;
    const begin = index;
    while (index < body.len and (if (hexadecimal) std.ascii.isHex(body[index]) else std.ascii.isDigit(body[index]))) : (index += 1) {}
    if (index == begin) return error.InvalidNumber;
    if (!hexadecimal and index - begin > 1 and body[begin] == '0') return error.InvalidNumber;
    var fraction = false;
    if (index < body.len and body[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < body.len and (if (hexadecimal) std.ascii.isHex(body[index]) else std.ascii.isDigit(body[index]))) : (index += 1) {}
        if (index == fraction_start) return error.InvalidNumber;
        fraction = true;
    }
    var exponent = false;
    if (index < body.len and std.ascii.toLower(body[index]) == (if (hexadecimal) @as(u8, 'p') else @as(u8, 'e'))) {
        index += 1;
        if (index < body.len and (body[index] == '+' or body[index] == '-')) index += 1;
        const exponent_start = index;
        while (index < body.len and std.ascii.isDigit(body[index])) : (index += 1) {}
        if (index == exponent_start) return error.InvalidNumber;
        exponent = true;
    }
    if (index != body.len or (hexadecimal and !exponent) or (!fraction and !exponent)) return error.InvalidNumber;
}

fn hex4(text: []const u8, index: *usize) Error!u21 {
    if (text.len - index.* < 4) return error.InvalidEscape;
    var scalar: u21 = 0;
    for (text[index.*..][0..4]) |byte| {
        scalar = scalar * 16 + (std.fmt.charToDigit(byte, 16) catch return error.InvalidEscape);
    }
    index.* += 4;
    return scalar;
}

fn escape(text: []const u8, index: *usize, bytes: bool) Error!u21 {
    if (index.* == text.len) return error.InvalidEscape;
    const byte = text[index.*];
    index.* += 1;
    return switch (byte) {
        '"', '/', '\\' => byte,
        '\'' => if (bytes) @as(u21, '\'') else error.InvalidEscape,
        'b' => 8,
        'f' => 12,
        'n' => 10,
        'r' => 13,
        't' => 9,
        'u' => blk: {
            if (index.* < text.len and text[index.*] == '{') {
                index.* += 1;
                const start = index.*;
                var scalar: u32 = 0;
                while (index.* < text.len and text[index.*] != '}') : (index.* += 1) {
                    const digit = std.fmt.charToDigit(text[index.*], 16) catch return error.InvalidEscape;
                    if (scalar > (0x10ffff - @as(u32, digit)) / 16) return error.InvalidEscape;
                    scalar = scalar * 16 + digit;
                }
                if (index.* == start or index.* == text.len or (scalar >= 0xd800 and scalar <= 0xdfff)) return error.InvalidEscape;
                index.* += 1;
                break :blk @intCast(scalar);
            }
            var scalar = try hex4(text, index);
            if (scalar >= 0xd800 and scalar <= 0xdbff) {
                if (text.len - index.* < 2 or text[index.*] != '\\' or text[index.* + 1] != 'u') return error.InvalidEscape;
                index.* += 2;
                const low = try hex4(text, index);
                if (low < 0xdc00 or low > 0xdfff) return error.InvalidEscape;
                scalar = 0x10000 + (scalar - 0xd800) * 0x400 + (low - 0xdc00);
            } else if (scalar >= 0xdc00 and scalar <= 0xdfff) return error.InvalidEscape;
            break :blk scalar;
        },
        else => error.InvalidEscape,
    };
}

pub fn string(allocator: std.mem.Allocator, lexeme: []const u8) Error!Literal {
    const quote = std.mem.indexOfAny(u8, lexeme, "\"'") orelse return error.InvalidEscape;
    const is_bytes = lexeme[quote] == '\'';
    if (lexeme.len < quote + 2 or lexeme[lexeme.len - 1] != lexeme[quote]) return error.InvalidEscape;
    const text = lexeme[quote + 1 .. lexeme.len - 1];
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        index += 1;
        if (byte != '\\') {
            try output.append(allocator, byte);
        } else {
            const scalar = try escape(text, &index, is_bytes);
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(scalar, &encoded) catch return error.InvalidEscape;
            try output.appendSlice(allocator, encoded[0..length]);
        }
    }
    if (quote != 0) {
        const length = try compactQualified(output.items);
        output.items.len = length;
        if (std.ascii.eqlIgnoreCase(lexeme[0..quote], "h")) {
            if (length % 2 != 0) return error.InvalidByteString;
            var i: usize = 0;
            while (i < length / 2) : (i += 1) {
                const high = std.fmt.charToDigit(output.items[i * 2], 16) catch return error.InvalidByteString;
                const low = std.fmt.charToDigit(output.items[i * 2 + 1], 16) catch return error.InvalidByteString;
                output.items[i] = high * 16 + low;
            }
            output.items.len = length / 2;
        } else if (std.ascii.eqlIgnoreCase(lexeme[0..quote], "b64")) {
            output.items.len = try decodeBase64(output.items);
        } else return error.InvalidByteString;
    }
    const owned = try output.toOwnedSlice(allocator);
    return if (is_bytes) .{ .bytes = owned } else .{ .text = owned };
}

fn compactQualified(bytes: []u8) Error!usize {
    var write: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        switch (bytes[index]) {
            ' ', '\n' => index += 1,
            '\r' => {
                if (index + 1 == bytes.len or bytes[index + 1] != '\n') return error.InvalidByteString;
                index += 2;
            },
            ';' => {
                while (index < bytes.len and bytes[index] != '\n' and bytes[index] != '\r') {
                    const byte = bytes[index];
                    if (byte < 0x80) {
                        if (byte < 0x20 or byte == 0x7f) return error.InvalidByteString;
                        index += 1;
                    } else {
                        const length = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidByteString;
                        if (bytes.len - index < length) return error.InvalidByteString;
                        const scalar = std.unicode.utf8Decode(bytes[index..][0..length]) catch return error.InvalidByteString;
                        if (scalar < 0xa0 or scalar > 0x10fffd) return error.InvalidByteString;
                        index += length;
                    }
                }
                if (index == bytes.len) return error.InvalidByteString;
            },
            else => {
                bytes[write] = bytes[index];
                write += 1;
                index += 1;
            },
        }
    }
    return write;
}

fn decodeBase64(bytes: []u8) Error!usize {
    var meaningful = bytes.len;
    while (meaningful > 0 and bytes[meaningful - 1] == '=') : (meaningful -= 1) {}
    const padding = bytes.len - meaningful;
    if (padding > 2 or meaningful % 4 == 1 or (padding != 0 and (bytes.len % 4 != 0 or padding != (4 - meaningful % 4) % 4))) return error.InvalidByteString;
    var accumulator: u16 = 0;
    var bits: u4 = 0;
    var written: usize = 0;
    for (bytes[0..meaningful]) |byte| {
        const digit: u8 = switch (byte) {
            'A'...'Z' => byte - 'A',
            'a'...'z' => byte - 'a' + 26,
            '0'...'9' => byte - '0' + 52,
            '-', '+' => 62,
            '_', '/' => 63,
            else => return error.InvalidByteString,
        };
        accumulator = (accumulator << 6) | digit;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            bytes[written] = @intCast(accumulator >> @as(u4, bits));
            written += 1;
            accumulator &= (@as(u16, 1) << bits) - 1;
        }
    }
    if (accumulator != 0) return error.InvalidByteString;
    return written;
}

test "integers preserve the full CBOR wire domain" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(std.math.maxInt(u64), (try number(allocator, "18446744073709551615")).unsigned);
    try std.testing.expectEqual(std.math.minInt(i65), (try number(allocator, "-18446744073709551616")).negative);
    try std.testing.expectError(error.IntegerOverflow, number(allocator, "18446744073709551616"));
    try std.testing.expectError(error.IntegerOverflow, number(allocator, "-18446744073709551617"));
    try std.testing.expectError(error.InvalidNumber, number(allocator, "01"));
}

test "updated escapes and qualified byte comments decode in order" {
    const allocator = std.testing.allocator;
    const text = try string(allocator, "\"\\u{1f073}\\uD83C\\uDC73\"");
    defer allocator.free(text.text);
    try std.testing.expectEqualStrings("🁳🁳", text.text);
    const bytes = try string(allocator, "h'43 ; \\'CBOR\\'\n42'");
    defer allocator.free(bytes.bytes);
    try std.testing.expectEqualStrings("CB", bytes.bytes);
    const base64 = try string(allocator, "b64'YQ=='");
    defer allocator.free(base64.bytes);
    try std.testing.expectEqualStrings("a", base64.bytes);
    try std.testing.expectError(error.InvalidEscape, string(allocator, "\"\\u{d800}\""));
}

test "float syntax retains exact spelling across integer radices" {
    const allocator = std.testing.allocator;
    const decimal = try number(allocator, "1.25e2");
    try std.testing.expectEqual(@as(f64, 125), decimal.float.value);
    try std.testing.expectEqualStrings("1.25e2", decimal.float.lexeme);
    try std.testing.expectEqual(@as(f64, 7.75), (try number(allocator, "0x1.fp2")).float.value);
    try std.testing.expectEqual(@as(f64, 350), (try number(allocator, "0b11.5e2")).float.value);
    try std.testing.expectEqual(@as(f64, 1200), (try number(allocator, "0x1.2e3")).float.value);
    try std.testing.expectEqual(@as(f64, 100), (try number(allocator, "0x1e+2")).float.value);
    try std.testing.expectEqual(@as(u64, 0x1e2), (try number(allocator, "0x1e2")).unsigned);
    try std.testing.expectError(error.InvalidNumber, number(allocator, "0x1.2ap"));
}
