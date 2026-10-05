//! CBOR initial bytes and arguments (RFC 8949 Section 3).

const std = @import("std");

pub const Major = enum(u3) {
    unsigned = 0,
    negative = 1,
    bytes = 2,
    text = 3,
    array = 4,
    map = 5,
    tag = 6,
    simple = 7,
};

/// Additional information marking an indefinite length (majors 2-5) or a break (major 7).
pub const indefinite_info: u5 = 31;
pub const break_byte: u8 = 0xff;
/// Longest encoded head: initial byte plus an eight-byte argument.
pub const max_len = 9;

pub const Head = struct {
    major: Major,
    info: u5,
    /// Argument value; zero for indefinite lengths and break. For floats it holds the raw bits.
    arg: u64,
    /// Encoded head length in bytes (1, 2, 3, 5, or 9).
    len: u8,

    pub fn isIndefinite(h: Head) bool {
        return h.info == indefinite_info;
    }

    pub fn isBreak(h: Head) bool {
        return h.major == .simple and h.info == indefinite_info;
    }

    /// Whether the argument uses its shortest form (RFC 8949 Section 4.2.1).
    pub fn hasPreferredArgument(h: Head) bool {
        return switch (h.info) {
            0...23 => true,
            24 => h.arg >= 24,
            25 => h.arg > 0xff,
            26 => h.arg > 0xffff,
            27 => h.arg > 0xffff_ffff,
            28...31 => false,
        };
    }
};

pub const ParseError = error{
    UnexpectedEndOfInput,
    ReservedAdditionalInfo,
    InvalidIndefiniteLength,
    InvalidSimpleValue,
};

/// Parses the head starting at `pos` without consuming anything.
pub fn parse(bytes: []const u8, pos: usize) ParseError!Head {
    if (pos >= bytes.len) return error.UnexpectedEndOfInput;
    const initial = bytes[pos];
    const major: Major = @enumFromInt(@as(u3, @intCast(initial >> 5)));
    const info: u5 = @truncate(initial);
    const rest = bytes[pos + 1 ..];
    var h: Head = .{ .major = major, .info = info, .arg = 0, .len = 1 };
    switch (info) {
        0...23 => h.arg = info,
        24 => {
            if (rest.len < 1) return error.UnexpectedEndOfInput;
            h.arg = rest[0];
            h.len = 2;
        },
        25 => {
            if (rest.len < 2) return error.UnexpectedEndOfInput;
            h.arg = std.mem.readInt(u16, rest[0..2], .big);
            h.len = 3;
        },
        26 => {
            if (rest.len < 4) return error.UnexpectedEndOfInput;
            h.arg = std.mem.readInt(u32, rest[0..4], .big);
            h.len = 5;
        },
        27 => {
            if (rest.len < 8) return error.UnexpectedEndOfInput;
            h.arg = std.mem.readInt(u64, rest[0..8], .big);
            h.len = 9;
        },
        28...30 => return error.ReservedAdditionalInfo,
        31 => switch (major) {
            .unsigned, .negative, .tag => return error.InvalidIndefiniteLength,
            .bytes, .text, .array, .map, .simple => {},
        },
    }
    if (major == .simple and info == 24 and h.arg < 32) return error.InvalidSimpleValue;
    return h;
}

/// Encodes a head with the shortest argument form into `buf`.
pub fn encode(buf: *[max_len]u8, major: Major, arg: u64) []const u8 {
    const mt: u8 = @as(u8, @intFromEnum(major)) << 5;
    if (arg < 24) {
        buf[0] = mt | @as(u8, @intCast(arg));
        return buf[0..1];
    }
    if (arg <= 0xff) {
        buf[0] = mt | 24;
        buf[1] = @intCast(arg);
        return buf[0..2];
    }
    if (arg <= 0xffff) {
        buf[0] = mt | 25;
        std.mem.writeInt(u16, buf[1..3], @intCast(arg), .big);
        return buf[0..3];
    }
    if (arg <= 0xffff_ffff) {
        buf[0] = mt | 26;
        std.mem.writeInt(u32, buf[1..5], @intCast(arg), .big);
        return buf[0..5];
    }
    buf[0] = mt | 27;
    std.mem.writeInt(u64, buf[1..9], arg, .big);
    return buf[0..9];
}

test "encode uses the shortest argument" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0x17}, encode(&buf, .unsigned, 23));
    try std.testing.expectEqualSlices(u8, &.{ 0x18, 0x18 }, encode(&buf, .unsigned, 24));
    try std.testing.expectEqualSlices(u8, &.{ 0x19, 0x01, 0x00 }, encode(&buf, .unsigned, 256));
    try std.testing.expectEqualSlices(u8, &.{ 0x1a, 0x00, 0x01, 0x00, 0x00 }, encode(&buf, .unsigned, 65536));
    try std.testing.expectEqualSlices(u8, &.{ 0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, encode(&buf, .negative, std.math.maxInt(u64)));
    try std.testing.expectEqualSlices(u8, &.{ 0x9a, 0xff, 0xff, 0xff, 0xff }, encode(&buf, .array, 0xffff_ffff));
}

test "parse rejects malformed heads" {
    try std.testing.expectError(error.UnexpectedEndOfInput, parse(&.{}, 0));
    try std.testing.expectError(error.UnexpectedEndOfInput, parse(&.{ 0x19, 0x01 }, 0));
    try std.testing.expectError(error.ReservedAdditionalInfo, parse(&.{0x1c}, 0));
    try std.testing.expectError(error.ReservedAdditionalInfo, parse(&.{0xfe}, 0));
    try std.testing.expectError(error.InvalidIndefiniteLength, parse(&.{0x1f}, 0));
    try std.testing.expectError(error.InvalidIndefiniteLength, parse(&.{0x3f}, 0));
    try std.testing.expectError(error.InvalidIndefiniteLength, parse(&.{0xdf}, 0));
    try std.testing.expectError(error.InvalidSimpleValue, parse(&.{ 0xf8, 0x1f }, 0));
    const h = try parse(&.{ 0x00, 0x18, 0x01 }, 1);
    try std.testing.expectEqual(@as(u64, 1), h.arg);
    try std.testing.expect(!h.hasPreferredArgument());
    try std.testing.expect((try parse(&.{0xff}, 0)).isBreak());
}
