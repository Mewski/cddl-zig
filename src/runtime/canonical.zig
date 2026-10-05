//! Recognition of the map-key equivalence form.
//!
//! The equivalence form is core deterministic encoding (RFC 8949 Section 4.2.1)
//! with -0.0 written as 0.0 and NaN written without its sign bit, so two keys
//! are equivalent under RFC 8949 Section 5.6.1 exactly when their equivalence
//! forms are byte-identical.

const std = @import("std");
const head = @import("head.zig");
const float = @import("float.zig");

/// Nesting beyond this is reported as not canonical; callers then take the
/// allocation-based canonicalization path, which is bounded by decoder limits.
const max_nesting = 32;

/// Whether `bytes` holds exactly one data item already in equivalence form.
/// Malformed input yields false.
pub fn isKeyCanonical(bytes: []const u8) bool {
    var pos: usize = 0;
    if (!item(bytes, &pos, 0)) return false;
    return pos == bytes.len;
}

fn item(bytes: []const u8, pos: *usize, depth: u32) bool {
    const h = head.parse(bytes, pos.*) catch return false;
    if (h.isIndefinite()) return false;
    if (h.major == .simple) {
        if (float.Width.fromInfo(h.info)) |width| {
            const x = float.decode(.{ .width = width, .bits = h.arg });
            const p = float.preferred(float.keyNormalized(x));
            if (p.width != width or p.bits != h.arg) return false;
        }
    } else if (!h.hasPreferredArgument()) {
        return false;
    }
    pos.* += h.len;

    switch (h.major) {
        .unsigned, .negative, .simple => return true,
        .bytes, .text => {
            if (h.arg > bytes.len - pos.*) return false;
            pos.* += @intCast(h.arg);
            return true;
        },
        .array => {
            if (depth >= max_nesting) return false;
            var i: u64 = 0;
            while (i < h.arg) : (i += 1) {
                if (!item(bytes, pos, depth + 1)) return false;
            }
            return true;
        },
        .map => {
            if (depth >= max_nesting) return false;
            var previous: ?[]const u8 = null;
            var i: u64 = 0;
            while (i < h.arg) : (i += 1) {
                const key_start = pos.*;
                if (!item(bytes, pos, depth + 1)) return false;
                const key = bytes[key_start..pos.*];
                if (previous) |prev| {
                    if (std.mem.order(u8, prev, key) != .lt) return false;
                }
                previous = key;
                if (!item(bytes, pos, depth + 1)) return false;
            }
            return true;
        },
        .tag => {
            if (depth >= max_nesting) return false;
            return item(bytes, pos, depth + 1);
        },
    }
}

test "equivalence form recognition" {
    try std.testing.expect(isKeyCanonical(&.{0x01}));
    try std.testing.expect(isKeyCanonical(&.{ 0x62, 'a', 'b' }));
    try std.testing.expect(isKeyCanonical(&.{ 0xa2, 0x01, 0x02, 0x03, 0x04 }));
    try std.testing.expect(isKeyCanonical(&.{ 0xf9, 0x00, 0x00 }));
    try std.testing.expect(isKeyCanonical(&.{ 0xf9, 0x7e, 0x00 }));
    try std.testing.expect(isKeyCanonical(&.{ 0xc1, 0x1a, 0x51, 0x4b, 0x67, 0xb0 }));

    try std.testing.expect(!isKeyCanonical(&.{ 0x18, 0x01 }));
    try std.testing.expect(!isKeyCanonical(&.{ 0x7f, 0x61, 'a', 0xff }));
    try std.testing.expect(!isKeyCanonical(&.{ 0xa2, 0x03, 0x04, 0x01, 0x02 }));
    try std.testing.expect(!isKeyCanonical(&.{ 0xf9, 0x80, 0x00 }));
    try std.testing.expect(!isKeyCanonical(&.{ 0xf9, 0xfe, 0x00 }));
    try std.testing.expect(!isKeyCanonical(&.{ 0xfa, 0x3f, 0x80, 0x00, 0x00 }));
    try std.testing.expect(!isKeyCanonical(&.{ 0x01, 0x02 }));
    try std.testing.expect(!isKeyCanonical(&.{0x62}));
}
