//! Bit-exact conversions between CBOR half, single, and double precision floats.
//!
//! Conversions operate on bit patterns so NaN payloads and signs survive unchanged.

const std = @import("std");

pub const Width = enum {
    half,
    single,
    double,

    /// Additional information value used to encode this width in major type 7.
    pub fn info(w: Width) u5 {
        return switch (w) {
            .half => 25,
            .single => 26,
            .double => 27,
        };
    }

    pub fn fromInfo(additional: u5) ?Width {
        return switch (additional) {
            25 => .half,
            26 => .single,
            27 => .double,
            else => null,
        };
    }
};

/// A float bit pattern of a given width.
pub const Encoded = struct {
    width: Width,
    bits: u64,
};

const sign_bit: u64 = 1 << 63;
const mantissa_mask: u64 = (1 << 52) - 1;

fn lowBits(n: u6) u64 {
    return (@as(u64, 1) << n) - 1;
}

pub fn fromHalf(h: u16) f64 {
    const sign: u64 = @as(u64, h >> 15) << 63;
    const exponent: u64 = (h >> 10) & 0x1f;
    const mantissa: u64 = h & 0x3ff;
    if (exponent == 0) {
        const magnitude: f64 = @as(f64, @floatFromInt(mantissa)) * 0x1p-24;
        return @bitCast(sign | @as(u64, @bitCast(magnitude)));
    }
    if (exponent == 0x1f) return @bitCast(sign | 0x7ff0_0000_0000_0000 | (mantissa << 42));
    return @bitCast(sign | ((exponent + (1023 - 15)) << 52) | (mantissa << 42));
}

pub fn fromSingle(s: u32) f64 {
    const sign: u64 = @as(u64, s >> 31) << 63;
    const exponent: u64 = (s >> 23) & 0xff;
    const mantissa: u64 = s & 0x7f_ffff;
    if (exponent == 0) {
        const magnitude: f64 = @as(f64, @floatFromInt(mantissa)) * 0x1p-149;
        return @bitCast(sign | @as(u64, @bitCast(magnitude)));
    }
    if (exponent == 0xff) return @bitCast(sign | 0x7ff0_0000_0000_0000 | (mantissa << 29));
    return @bitCast(sign | ((exponent + (1023 - 127)) << 52) | (mantissa << 29));
}

pub fn decode(e: Encoded) f64 {
    return switch (e.width) {
        .half => fromHalf(@truncate(e.bits)),
        .single => fromSingle(@truncate(e.bits)),
        .double => @bitCast(e.bits),
    };
}

/// Shortest encoding that preserves the value, including NaN payloads
/// (RFC 8949 Section 4.1 preferred serialization).
pub fn preferred(x: f64) Encoded {
    const bits: u64 = @bitCast(x);
    const sign: u64 = bits >> 63;
    const exponent: u64 = (bits >> 52) & 0x7ff;
    const mantissa: u64 = bits & mantissa_mask;
    const double: Encoded = .{ .width = .double, .bits = bits };

    if (exponent == 0x7ff) {
        if (mantissa & lowBits(42) == 0) return .{ .width = .half, .bits = (sign << 15) | 0x7c00 | (mantissa >> 42) };
        if (mantissa & lowBits(29) == 0) return .{ .width = .single, .bits = (sign << 31) | 0x7f80_0000 | (mantissa >> 29) };
        return double;
    }
    if (exponent == 0) {
        if (mantissa == 0) return .{ .width = .half, .bits = sign << 15 };
        return double;
    }

    const e: i64 = @as(i64, @intCast(exponent)) - 1023;
    const significand = mantissa | (1 << 52);
    if (e >= -14 and e <= 15) {
        if (mantissa & lowBits(42) == 0) {
            const biased: u64 = @intCast(e + 15);
            return .{ .width = .half, .bits = (sign << 15) | (biased << 10) | (mantissa >> 42) };
        }
    } else if (e >= -24 and e < -14) {
        const shift: u6 = @intCast(28 - e);
        if (significand & lowBits(shift) == 0) return .{ .width = .half, .bits = (sign << 15) | (significand >> shift) };
    }
    if (e >= -126 and e <= 127) {
        if (mantissa & lowBits(29) == 0) {
            const biased: u64 = @intCast(e + 127);
            return .{ .width = .single, .bits = (sign << 31) | (biased << 23) | (mantissa >> 29) };
        }
    } else if (e >= -149 and e < -126) {
        const shift: u6 = @intCast(-97 - e);
        if (significand & lowBits(shift) == 0) return .{ .width = .single, .bits = (sign << 31) | (significand >> shift) };
    }
    return double;
}

/// Folds values that are equivalent as map keys (RFC 8949 Section 5.6.1):
/// -0.0 becomes 0.0 and NaN loses its sign bit.
pub fn keyNormalized(x: f64) f64 {
    if (x == 0) return 0.0;
    if (std.math.isNan(x)) return @bitCast(@as(u64, @bitCast(x)) & ~sign_bit);
    return x;
}

/// Data-model equality: numeric equality, with NaNs equal when their significands match.
pub fn eql(a: f64, b: f64) bool {
    if (std.math.isNan(a) or std.math.isNan(b)) {
        if (!std.math.isNan(a) or !std.math.isNan(b)) return false;
        return (@as(u64, @bitCast(a)) & mantissa_mask) == (@as(u64, @bitCast(b)) & mantissa_mask);
    }
    return a == b;
}

const testing = std.testing;

fn expectPreferred(x: f64, width: Width, bits: u64) !void {
    const p = preferred(x);
    try testing.expectEqual(width, p.width);
    try testing.expectEqual(bits, p.bits);
    try testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(decode(p))));
}

test "preferred serialization picks the shortest exact width" {
    try expectPreferred(0.0, .half, 0x0000);
    try expectPreferred(-0.0, .half, 0x8000);
    try expectPreferred(1.0, .half, 0x3c00);
    try expectPreferred(1.5, .half, 0x3e00);
    try expectPreferred(65504.0, .half, 0x7bff);
    try expectPreferred(5.960464477539063e-8, .half, 0x0001);
    try expectPreferred(0.00006103515625, .half, 0x0400);
    try expectPreferred(-4.0, .half, 0xc400);
    try expectPreferred(std.math.inf(f64), .half, 0x7c00);
    try expectPreferred(-std.math.inf(f64), .half, 0xfc00);
    try expectPreferred(100000.0, .single, 0x47c3_5000);
    try expectPreferred(3.4028234663852886e+38, .single, 0x7f7f_ffff);
    try expectPreferred(0x1p-149, .single, 0x0000_0001);
    try expectPreferred(0x1p-25, .single, 0x3300_0000);
    try expectPreferred(1.1, .double, 0x3ff1_9999_9999_999a);
    try expectPreferred(1.0e+300, .double, 0x7e37_e43c_8800_759c);
    try expectPreferred(0x1p-1074, .double, 1);
}

test "NaN payloads are preserved across widths" {
    try expectPreferred(@bitCast(@as(u64, 0x7ff8_0000_0000_0000)), .half, 0x7e00);
    try expectPreferred(@bitCast(@as(u64, 0xfff8_0000_0000_0000)), .half, 0xfe00);
    try expectPreferred(@bitCast(@as(u64, 0x7ff0_0020_0000_0000)), .single, 0x7f80_0100);
    try expectPreferred(@bitCast(@as(u64, 0x7ff0_0000_0000_0001)), .double, 0x7ff0_0000_0000_0001);
    try testing.expectEqual(@as(u64, 0x7ff0_0400_0000_0000), @as(u64, @bitCast(fromHalf(0x7c01))));
    try testing.expectEqual(@as(u64, 0x7ff0_0000_2000_0000), @as(u64, @bitCast(fromSingle(0x7f80_0001))));
}

test "key normalization and equality" {
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(keyNormalized(-0.0))));
    const negative_nan: f64 = @bitCast(@as(u64, 0xfff8_0000_0000_0000));
    try testing.expectEqual(@as(u64, 0x7ff8_0000_0000_0000), @as(u64, @bitCast(keyNormalized(negative_nan))));
    try testing.expect(eql(0.0, -0.0));
    try testing.expect(eql(negative_nan, std.math.nan(f64)));
    try testing.expect(!eql(std.math.nan(f64), 1.0));
    try testing.expect(!eql(1.0, 2.0));
}
