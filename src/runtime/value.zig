//! Generic CBOR data item in the RFC 8949 generic data model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const float = @import("float.zig");

pub const Value = union(enum) {
    /// Major types 0 and 1; covers -2^64 through 2^64 - 1.
    integer: i65,
    bytes: []const u8,
    /// Valid UTF-8.
    text: []const u8,
    array: []Value,
    /// Entries in input order; decoded maps never hold equivalent keys.
    map: []Entry,
    tag: Tag,
    /// Simple values other than false, true, null, and undefined (0-19 and 32-255).
    simple: u8,
    boolean: bool,
    null,
    undefined,
    /// Floating-point value of any width; encoders emit the shortest exact width.
    float: f64,

    pub const Entry = struct {
        key: Value,
        value: Value,
    };

    pub const Tag = struct {
        number: u64,
        content: *Value,
    };

    /// Frees a value whose storage was allocated by `gpa`, as produced by the decoder.
    pub fn deinit(v: Value, gpa: Allocator) void {
        switch (v) {
            .bytes, .text => |s| gpa.free(s),
            .array => |items| {
                for (items) |child| child.deinit(gpa);
                gpa.free(items);
            },
            .map => |entries| {
                for (entries) |entry| {
                    entry.key.deinit(gpa);
                    entry.value.deinit(gpa);
                }
                gpa.free(entries);
            },
            .tag => |t| {
                t.content.deinit(gpa);
                gpa.destroy(t.content);
            },
            .integer, .simple, .boolean, .null, .undefined, .float => {},
        }
    }

    /// Generic data model equality (RFC 8949 Section 5.6.1): maps compare as
    /// sets of pairs, -0.0 equals 0.0, NaNs are equal when their significands match.
    pub fn eql(a: Value, b: Value) bool {
        if (simpleNumber(a)) |sa| {
            const sb = simpleNumber(b) orelse return false;
            return sa == sb;
        }
        if (simpleNumber(b) != null) return false;
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        switch (a) {
            .integer => |x| return x == b.integer,
            .bytes => |x| return std.mem.eql(u8, x, b.bytes),
            .text => |x| return std.mem.eql(u8, x, b.text),
            .array => |xs| {
                const ys = b.array;
                if (xs.len != ys.len) return false;
                for (xs, ys) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
            .map => |xs| {
                const ys = b.map;
                if (xs.len != ys.len) return false;
                outer: for (xs) |x| {
                    for (ys) |y| {
                        if (x.key.eql(y.key)) {
                            if (!x.value.eql(y.value)) return false;
                            continue :outer;
                        }
                    }
                    return false;
                }
                return true;
            },
            .tag => |t| return t.number == b.tag.number and t.content.eql(b.tag.content.*),
            .float => |x| return float.eql(x, b.float),
            .simple, .boolean, .null, .undefined => unreachable,
        }
    }

    fn simpleNumber(v: Value) ?u8 {
        return switch (v) {
            .simple => |s| s,
            .boolean => |x| if (x) 21 else 20,
            .null => 22,
            .undefined => 23,
            else => null,
        };
    }
};

test "data model equality" {
    var one: Value = .{ .integer = 1 };
    const a_entries = [_]Value.Entry{
        .{ .key = .{ .text = "a" }, .value = .{ .integer = 1 } },
        .{ .key = .{ .integer = -1 }, .value = .{ .float = 0.0 } },
    };
    const b_entries = [_]Value.Entry{
        .{ .key = .{ .integer = -1 }, .value = .{ .float = -0.0 } },
        .{ .key = .{ .text = "a" }, .value = .{ .integer = 1 } },
    };
    var a_buf = a_entries;
    var b_buf = b_entries;
    try std.testing.expect((Value{ .map = &a_buf }).eql(.{ .map = &b_buf }));
    try std.testing.expect((Value{ .simple = 20 }).eql(.{ .boolean = false }));
    try std.testing.expect(!(Value{ .integer = 2 }).eql(.{ .simple = 2 }));
    try std.testing.expect(!(Value{ .integer = 1 }).eql(.{ .float = 1.0 }));
    try std.testing.expect(!(Value{ .bytes = "a" }).eql(.{ .text = "a" }));
    try std.testing.expect((Value{ .tag = .{ .number = 2, .content = &one } }).eql(.{ .tag = .{ .number = 2, .content = &one } }));
    try std.testing.expect(!(Value{ .tag = .{ .number = 3, .content = &one } }).eql(.{ .tag = .{ .number = 2, .content = &one } }));
}
