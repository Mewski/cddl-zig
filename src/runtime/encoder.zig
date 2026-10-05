//! CBOR encoder emitting core deterministic encoding (RFC 8949 Section 4.2.1):
//! shortest arguments, definite lengths, shortest exact floats, and map keys
//! in bytewise lexicographic order of their encodings.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const head = @import("head.zig");
const float = @import("float.zig");
const canonical = @import("canonical.zig");
const decoder = @import("decoder.zig");
const Value = @import("value.zig").Value;

const maxInt = std.math.maxInt;

pub const EncodeError = errors.EncodeError;

pub const ValueMode = enum {
    /// Core deterministic encoding.
    deterministic,
    /// Core deterministic encoding with -0.0 folded to 0.0 and NaN sign bits
    /// cleared, so equal bytes mean equivalent map keys (RFC 8949 Section 5.6.1).
    key_equivalence,
};

pub const Encoder = struct {
    sink: Sink,
    /// Bytes emitted so far.
    len: usize = 0,

    pub const Sink = union(enum) {
        /// Write failures surface as `error.WriteFailed`.
        writer: *std.Io.Writer,
        /// Overflow surfaces as `error.OutputCapacityExceeded`; output is `buffer[0..len]`.
        fixed: []u8,
        /// Growth failures surface as `error.OutOfMemory`.
        list: List,
    };

    pub const List = struct {
        gpa: Allocator,
        bytes: *std.ArrayList(u8),
    };

    pub fn initWriter(w: *std.Io.Writer) Encoder {
        return .{ .sink = .{ .writer = w } };
    }

    pub fn initFixed(buffer: []u8) Encoder {
        return .{ .sink = .{ .fixed = buffer } };
    }

    pub fn initList(gpa: Allocator, list: *std.ArrayList(u8)) Encoder {
        return .{ .sink = .{ .list = .{ .gpa = gpa, .bytes = list } } };
    }

    /// Appends bytes that already hold complete, valid CBOR data items.
    pub fn writeEncoded(e: *Encoder, bytes: []const u8) EncodeError!void {
        const new_len = std.math.add(usize, e.len, bytes.len) catch return error.OutputCapacityExceeded;
        switch (e.sink) {
            .writer => |w| w.writeAll(bytes) catch return error.WriteFailed,
            .fixed => |buffer| {
                if (new_len > buffer.len) return error.OutputCapacityExceeded;
                @memcpy(buffer[e.len..new_len], bytes);
            },
            .list => |l| try l.bytes.appendSlice(l.gpa, bytes),
        }
        e.len = new_len;
    }

    fn writeHead(e: *Encoder, major: head.Major, arg: u64) EncodeError!void {
        var buf: [head.max_len]u8 = undefined;
        return e.writeEncoded(head.encode(&buf, major, arg));
    }

    pub fn writeUint(e: *Encoder, value: u64) EncodeError!void {
        return e.writeHead(.unsigned, value);
    }

    /// Writes the negative integer -1 - `arg`.
    pub fn writeNegative(e: *Encoder, arg: u64) EncodeError!void {
        return e.writeHead(.negative, arg);
    }

    pub fn writeInt(e: *Encoder, value: i65) EncodeError!void {
        if (value >= 0) return e.writeHead(.unsigned, @intCast(value));
        return e.writeHead(.negative, @intCast(-1 - value));
    }

    pub fn writeBytes(e: *Encoder, bytes: []const u8) EncodeError!void {
        try e.writeHead(.bytes, bytes.len);
        try e.writeEncoded(bytes);
    }

    /// Writes a text string; `text` must be valid UTF-8.
    pub fn writeText(e: *Encoder, text: []const u8) EncodeError!void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        try e.writeHead(.text, text.len);
        try e.writeEncoded(text);
    }

    /// Writes an array head; exactly `count` items must follow.
    pub fn writeArrayHeader(e: *Encoder, count: u64) EncodeError!void {
        return e.writeHead(.array, count);
    }

    /// Writes a map head; exactly `count` key/value pairs must follow in
    /// deterministic key order (see `MapBuilder` for runtime-ordered keys).
    pub fn writeMapHeader(e: *Encoder, count: u64) EncodeError!void {
        return e.writeHead(.map, count);
    }

    /// Writes a tag head; exactly one item must follow.
    pub fn writeTag(e: *Encoder, number: u64) EncodeError!void {
        return e.writeHead(.tag, number);
    }

    pub fn writeBool(e: *Encoder, value: bool) EncodeError!void {
        const byte: u8 = if (value) 0xf5 else 0xf4;
        return e.writeEncoded(&[1]u8{byte});
    }

    pub fn writeNull(e: *Encoder) EncodeError!void {
        return e.writeEncoded(&[1]u8{0xf6});
    }

    pub fn writeUndefined(e: *Encoder) EncodeError!void {
        return e.writeEncoded(&[1]u8{0xf7});
    }

    /// Writes simple value `value`; 24 through 31 have no valid encoding.
    pub fn writeSimple(e: *Encoder, value: u8) EncodeError!void {
        if (value >= 24 and value < 32) return error.InvalidSimpleValue;
        return e.writeHead(.simple, value);
    }

    /// Writes a float in its shortest exact width (preferred serialization).
    pub fn writeFloat(e: *Encoder, value: f64) EncodeError!void {
        return e.writeFloatEncoded(float.preferred(value));
    }

    /// Writes half-precision bits verbatim.
    pub fn writeFloat16Bits(e: *Encoder, bits: u16) EncodeError!void {
        return e.writeFloatEncoded(.{ .width = .half, .bits = bits });
    }

    /// Writes a single-precision float verbatim; not deterministic when a
    /// shorter exact width exists.
    pub fn writeFloat32(e: *Encoder, value: f32) EncodeError!void {
        return e.writeFloatEncoded(.{ .width = .single, .bits = @as(u32, @bitCast(value)) });
    }

    /// Writes a double-precision float verbatim; not deterministic when a
    /// shorter exact width exists.
    pub fn writeFloat64(e: *Encoder, value: f64) EncodeError!void {
        return e.writeFloatEncoded(.{ .width = .double, .bits = @bitCast(value) });
    }

    fn writeFloatEncoded(e: *Encoder, f: float.Encoded) EncodeError!void {
        var buf: [9]u8 = undefined;
        buf[0] = 0xe0 | @as(u8, f.width.info());
        switch (f.width) {
            .half => {
                std.mem.writeInt(u16, buf[1..3], @intCast(f.bits), .big);
                return e.writeEncoded(buf[0..3]);
            },
            .single => {
                std.mem.writeInt(u32, buf[1..5], @intCast(f.bits), .big);
                return e.writeEncoded(buf[0..5]);
            },
            .double => {
                std.mem.writeInt(u64, buf[1..9], f.bits, .big);
                return e.writeEncoded(buf[0..9]);
            },
        }
    }

    /// Writes `value` in core deterministic encoding. `gpa` backs temporary
    /// map-key sorting storage.
    pub fn writeValue(e: *Encoder, gpa: Allocator, value: Value) EncodeError!void {
        return e.writeValueWithMode(gpa, value, .deterministic);
    }

    pub fn writeValueWithMode(e: *Encoder, gpa: Allocator, value: Value, mode: ValueMode) EncodeError!void {
        switch (value) {
            .integer => |v| try e.writeInt(v),
            .bytes => |v| try e.writeBytes(v),
            .text => |v| try e.writeText(v),
            .array => |items| {
                try e.writeArrayHeader(items.len);
                for (items) |item| try e.writeValueWithMode(gpa, item, mode);
            },
            .map => |entries| try e.writeMapEntries(gpa, entries, mode),
            .tag => |t| {
                try e.writeTag(t.number);
                try e.writeValueWithMode(gpa, t.content.*, mode);
            },
            .simple => |v| try e.writeSimple(v),
            .boolean => |v| try e.writeBool(v),
            .null => try e.writeNull(),
            .undefined => try e.writeUndefined(),
            .float => |v| try e.writeFloat(switch (mode) {
                .deterministic => v,
                .key_equivalence => float.keyNormalized(v),
            }),
        }
    }

    fn writeMapEntries(e: *Encoder, gpa: Allocator, entries: []const Value.Entry, mode: ValueMode) EncodeError!void {
        var keys: std.ArrayList(u8) = .empty;
        defer keys.deinit(gpa);
        const ranges = try gpa.alloc(Range, entries.len);
        defer gpa.free(ranges);

        var key_encoder = initList(gpa, &keys);
        var needs_equivalence_check = false;
        for (entries, ranges, 0..) |entry, *range, i| {
            const start = keys.items.len;
            try key_encoder.writeValueWithMode(gpa, entry.key, mode);
            range.* = .{ .start = start, .end = keys.items.len, .index = i };
            if (mode == .deterministic and !canonical.isKeyCanonical(keys.items[start..]))
                needs_equivalence_check = true;
        }
        sortRanges(keys.items, ranges);
        try requireDistinct(keys.items, ranges);
        if (needs_equivalence_check) try checkEquivalentValueKeys(gpa, entries);

        try e.writeMapHeader(entries.len);
        for (ranges) |range| {
            try e.writeEncoded(keys.items[range.start..range.end]);
            try e.writeValueWithMode(gpa, entries[range.index].value, mode);
        }
    }
};

const Range = struct {
    start: usize,
    end: usize,
    index: usize,
};

const RangeOrder = struct {
    bytes: []const u8,

    fn lessThan(ctx: RangeOrder, a: Range, b: Range) bool {
        return std.mem.order(u8, ctx.bytes[a.start..a.end], ctx.bytes[b.start..b.end]) == .lt;
    }
};

fn sortRanges(bytes: []const u8, ranges: []Range) void {
    std.mem.sortUnstable(Range, ranges, RangeOrder{ .bytes = bytes }, RangeOrder.lessThan);
}

fn requireDistinct(bytes: []const u8, sorted: []const Range) EncodeError!void {
    if (sorted.len < 2) return;
    for (sorted[1..], sorted[0 .. sorted.len - 1]) |b, a| {
        if (std.mem.eql(u8, bytes[a.start..a.end], bytes[b.start..b.end])) return error.DuplicateMapKey;
    }
}

fn checkEquivalentValueKeys(gpa: Allocator, entries: []const Value.Entry) EncodeError!void {
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(gpa);
    const ranges = try gpa.alloc(Range, entries.len);
    defer gpa.free(ranges);
    var key_encoder: Encoder = .initList(gpa, &keys);
    for (entries, ranges, 0..) |entry, *range, i| {
        const start = keys.items.len;
        try key_encoder.writeValueWithMode(gpa, entry.key, .key_equivalence);
        range.* = .{ .start = start, .end = keys.items.len, .index = i };
    }
    sortRanges(keys.items, ranges);
    try requireDistinct(keys.items, ranges);
}

/// Builds a map whose keys are only known at run time and emits it in
/// deterministic key order, rejecting equivalent keys.
///
/// For each entry call `beginKey`, encode the key through `encoder()`, call
/// `beginValue`, and encode the value; then call `finish`.
pub const MapBuilder = struct {
    gpa: Allocator,
    buffer: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    state: enum { idle, key, value } = .idle,

    const Entry = struct {
        key_start: usize,
        key_end: usize,
        end: usize,
    };

    pub fn init(gpa: Allocator) MapBuilder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *MapBuilder) void {
        b.buffer.deinit(b.gpa);
        b.entries.deinit(b.gpa);
    }

    /// Encoder appending to the builder's buffer; valid while the builder lives.
    pub fn encoder(b: *MapBuilder) Encoder {
        return .initList(b.gpa, &b.buffer);
    }

    pub fn beginKey(b: *MapBuilder) EncodeError!void {
        b.closeEntry();
        try b.entries.append(b.gpa, .{ .key_start = b.buffer.items.len, .key_end = 0, .end = 0 });
        b.state = .key;
    }

    pub fn beginValue(b: *MapBuilder) void {
        std.debug.assert(b.state == .key);
        b.entries.items[b.entries.items.len - 1].key_end = b.buffer.items.len;
        b.state = .value;
    }

    fn closeEntry(b: *MapBuilder) void {
        switch (b.state) {
            .idle => {},
            // Every key must be followed by beginValue before the next beginKey or finish.
            .key => unreachable,
            .value => {
                b.entries.items[b.entries.items.len - 1].end = b.buffer.items.len;
                b.state = .idle;
            },
        }
    }

    /// Emits the map to `out`. The builder may be reused after `reset`.
    pub fn finish(b: *MapBuilder, out: *Encoder) EncodeError!void {
        b.closeEntry();
        const entries = b.entries.items;
        const bytes = b.buffer.items;
        const ranges = try b.gpa.alloc(Range, entries.len);
        defer b.gpa.free(ranges);
        var needs_equivalence_check = false;
        for (entries, ranges, 0..) |entry, *range, i| {
            range.* = .{ .start = entry.key_start, .end = entry.key_end, .index = i };
            if (!canonical.isKeyCanonical(bytes[entry.key_start..entry.key_end])) needs_equivalence_check = true;
        }
        sortRanges(bytes, ranges);
        try requireDistinct(bytes, ranges);
        if (needs_equivalence_check) try checkEquivalentEncodedKeys(b.gpa, bytes, ranges);

        try out.writeMapHeader(entries.len);
        for (ranges) |range| {
            const entry = entries[range.index];
            try out.writeEncoded(bytes[entry.key_start..entry.end]);
        }
    }

    pub fn reset(b: *MapBuilder) void {
        b.buffer.clearRetainingCapacity();
        b.entries.clearRetainingCapacity();
        b.state = .idle;
    }
};

fn checkEquivalentEncodedKeys(gpa: Allocator, bytes: []const u8, key_ranges: []const Range) EncodeError!void {
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(gpa);
    const ranges = try gpa.alloc(Range, key_ranges.len);
    defer gpa.free(ranges);
    var key_encoder: Encoder = .initList(gpa, &keys);
    const options: decoder.DecodeOptions = .{ .limits = .{
        .max_items = maxInt(u64),
        .max_string_bytes = maxInt(u64),
        .max_allocation_bytes = maxInt(u64),
        .max_work = maxInt(u64),
    } };
    for (key_ranges, ranges) |key_range, *range| {
        const start = keys.items.len;
        const key_bytes = bytes[key_range.start..key_range.end];
        if (canonical.isKeyCanonical(key_bytes)) {
            try key_encoder.writeEncoded(key_bytes);
        } else {
            const key = decoder.decodeValue(gpa, key_bytes, options) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidEncodedItem,
            };
            defer key.deinit(gpa);
            try key_encoder.writeValueWithMode(gpa, key, .key_equivalence);
        }
        range.* = .{ .start = start, .end = keys.items.len, .index = key_range.index };
    }
    sortRanges(keys.items, ranges);
    try requireDistinct(keys.items, ranges);
}

/// Encodes `value` in core deterministic encoding into a new allocation.
pub fn encodeValueAlloc(gpa: Allocator, value: Value) EncodeError![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var e: Encoder = .initList(gpa, &list);
    try e.writeValue(gpa, value);
    return list.toOwnedSlice(gpa);
}

const testing = std.testing;

fn expectValueEncoding(expected: []const u8, value: Value) !void {
    const bytes = try encodeValueAlloc(testing.allocator, value);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, expected, bytes);
}

test "integers use the shortest argument" {
    const cases = [_]struct { value: i65, bytes: []const u8 }{
        .{ .value = 0, .bytes = &.{0x00} },
        .{ .value = 23, .bytes = &.{0x17} },
        .{ .value = 24, .bytes = &.{ 0x18, 0x18 } },
        .{ .value = 255, .bytes = &.{ 0x18, 0xff } },
        .{ .value = 256, .bytes = &.{ 0x19, 0x01, 0x00 } },
        .{ .value = 65535, .bytes = &.{ 0x19, 0xff, 0xff } },
        .{ .value = 65536, .bytes = &.{ 0x1a, 0x00, 0x01, 0x00, 0x00 } },
        .{ .value = 4294967295, .bytes = &.{ 0x1a, 0xff, 0xff, 0xff, 0xff } },
        .{ .value = 4294967296, .bytes = &.{ 0x1b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 } },
        .{ .value = maxInt(u64), .bytes = &.{ 0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } },
        .{ .value = -1, .bytes = &.{0x20} },
        .{ .value = -24, .bytes = &.{0x37} },
        .{ .value = -25, .bytes = &.{ 0x38, 0x18 } },
        .{ .value = -18446744073709551616, .bytes = &.{ 0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } },
    };
    for (cases) |c| try expectValueEncoding(c.bytes, .{ .integer = c.value });
}

test "floats use the shortest exact width" {
    const cases = [_]struct { value: f64, bytes: []const u8 }{
        .{ .value = 0.0, .bytes = &.{ 0xf9, 0x00, 0x00 } },
        .{ .value = -0.0, .bytes = &.{ 0xf9, 0x80, 0x00 } },
        .{ .value = 1.0, .bytes = &.{ 0xf9, 0x3c, 0x00 } },
        .{ .value = 1.5, .bytes = &.{ 0xf9, 0x3e, 0x00 } },
        .{ .value = 65504.0, .bytes = &.{ 0xf9, 0x7b, 0xff } },
        .{ .value = 5.960464477539063e-8, .bytes = &.{ 0xf9, 0x00, 0x01 } },
        .{ .value = 100000.0, .bytes = &.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 } },
        .{ .value = 3.4028234663852886e+38, .bytes = &.{ 0xfa, 0x7f, 0x7f, 0xff, 0xff } },
        .{ .value = 1.1, .bytes = &.{ 0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a } },
        .{ .value = 1.0e+300, .bytes = &.{ 0xfb, 0x7e, 0x37, 0xe4, 0x3c, 0x88, 0x00, 0x75, 0x9c } },
        .{ .value = std.math.inf(f64), .bytes = &.{ 0xf9, 0x7c, 0x00 } },
        .{ .value = -std.math.inf(f64), .bytes = &.{ 0xf9, 0xfc, 0x00 } },
        .{ .value = std.math.nan(f64), .bytes = &.{ 0xf9, 0x7e, 0x00 } },
    };
    for (cases) |c| try expectValueEncoding(c.bytes, .{ .float = c.value });

    var buf: [9]u8 = undefined;
    var e = Encoder.initFixed(&buf);
    try e.writeFloat32(1.0);
    try testing.expectEqualSlices(u8, &.{ 0xfa, 0x3f, 0x80, 0x00, 0x00 }, buf[0..e.len]);
}

test "scalars, strings, and tags" {
    try expectValueEncoding(&.{0xf4}, .{ .boolean = false });
    try expectValueEncoding(&.{0xf5}, .{ .boolean = true });
    try expectValueEncoding(&.{0xf6}, .null);
    try expectValueEncoding(&.{0xf7}, .undefined);
    try expectValueEncoding(&.{0xf0}, .{ .simple = 16 });
    try expectValueEncoding(&.{ 0xf8, 0xff }, .{ .simple = 255 });
    try expectValueEncoding(&.{0x40}, .{ .bytes = "" });
    try expectValueEncoding("\x64IETF", .{ .text = "IETF" });
    try expectValueEncoding("\x78\x18abcdefghijklmnopqrstuvwx", .{ .text = "abcdefghijklmnopqrstuvwx" });
    var content: Value = .{ .integer = 1363896240 };
    try expectValueEncoding(&.{ 0xc1, 0x1a, 0x51, 0x4b, 0x67, 0xb0 }, .{ .tag = .{ .number = 1, .content = &content } });

    var buf: [4]u8 = undefined;
    var e = Encoder.initFixed(&buf);
    try testing.expectError(error.InvalidUtf8, e.writeText("\xc3\x28"));
    try testing.expectError(error.InvalidSimpleValue, e.writeSimple(24));
    try testing.expectError(error.InvalidSimpleValue, e.writeSimple(31));
    try testing.expectEqual(@as(usize, 0), e.len);
}

test "map keys are sorted bytewise by encoding" {
    var one = [_]Value{.{ .integer = 1 }};
    var entries = [_]Value.Entry{
        .{ .key = .{ .text = "aa" }, .value = .{ .integer = 0 } },
        .{ .key = .{ .boolean = false }, .value = .{ .integer = 0 } },
        .{ .key = .{ .text = "b" }, .value = .{ .integer = 0 } },
        .{ .key = .{ .integer = 100 }, .value = .{ .integer = 0 } },
        .{ .key = .{ .array = &one }, .value = .{ .integer = 0 } },
        .{ .key = .{ .integer = -1 }, .value = .{ .integer = 0 } },
        .{ .key = .{ .integer = 10 }, .value = .{ .integer = 0 } },
    };
    try expectValueEncoding(&.{
        0xa7,
        0x0a,
        0x00,
        0x18,
        0x64,
        0x00,
        0x20,
        0x00,
        0x61,
        'b',
        0x00,
        0x62,
        'a',
        'a',
        0x00,
        0x81,
        0x01,
        0x00,
        0xf4,
        0x00,
    }, .{ .map = &entries });
}

test "equivalent map keys are rejected" {
    var ints = [_]Value.Entry{
        .{ .key = .{ .integer = 1 }, .value = .null },
        .{ .key = .{ .integer = 1 }, .value = .undefined },
    };
    try testing.expectError(error.DuplicateMapKey, encodeValueAlloc(testing.allocator, .{ .map = &ints }));

    var zeros = [_]Value.Entry{
        .{ .key = .{ .float = 0.0 }, .value = .null },
        .{ .key = .{ .float = 1.0 }, .value = .null },
        .{ .key = .{ .float = -0.0 }, .value = .null },
    };
    try testing.expectError(error.DuplicateMapKey, encodeValueAlloc(testing.allocator, .{ .map = &zeros }));

    var nans = [_]Value.Entry{
        .{ .key = .{ .float = @bitCast(@as(u64, 0x7ff8_0000_0000_0000)) }, .value = .null },
        .{ .key = .{ .float = @bitCast(@as(u64, 0xfff8_0000_0000_0000)) }, .value = .null },
    };
    try testing.expectError(error.DuplicateMapKey, encodeValueAlloc(testing.allocator, .{ .map = &nans }));

    var distinct = [_]Value.Entry{
        .{ .key = .{ .float = -0.0 }, .value = .null },
        .{ .key = .{ .integer = 0 }, .value = .null },
    };
    try expectValueEncoding(&.{ 0xa2, 0x00, 0xf6, 0xf9, 0x80, 0x00, 0xf6 }, .{ .map = &distinct });
}

test "output sinks report capacity failures" {
    var small: [2]u8 = undefined;
    var e = Encoder.initFixed(&small);
    try testing.expectError(error.OutputCapacityExceeded, e.writeUint(256));
    try testing.expectEqual(@as(usize, 0), e.len);
    try e.writeUint(24);
    try testing.expectEqualSlices(u8, &.{ 0x18, 0x18 }, small[0..e.len]);

    var buf: [3]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var we = Encoder.initWriter(&w);
    try we.writeUint(256);
    try testing.expectEqualSlices(u8, &.{ 0x19, 0x01, 0x00 }, w.buffered());
    try testing.expectError(error.WriteFailed, we.writeUint(0));
}

test "nonpreferred input re-encodes deterministically" {
    const gpa = testing.allocator;
    const input = [_]u8{ 0xbf, 0x61, 'b', 0x18, 0x01, 0x7f, 0x61, 'a', 0xff, 0xfa, 0x3f, 0xc0, 0x00, 0x00, 0xff };
    const value = try decoder.decodeValue(gpa, &input, .{});
    defer value.deinit(gpa);
    const bytes = try encodeValueAlloc(gpa, value);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xa2, 0x61, 'a', 0xf9, 0x3e, 0x00, 0x61, 'b', 0x01 }, bytes);
    try decoder.validate(gpa, bytes, .{ .require_deterministic = true });
    const again = try decoder.decodeValue(gpa, bytes, .{ .require_deterministic = true });
    defer again.deinit(gpa);
    try testing.expect(value.eql(again));
}

test "MapBuilder sorts runtime keys and rejects equivalent ones" {
    const gpa = testing.allocator;
    var b = MapBuilder.init(gpa);
    defer b.deinit();
    var ke = b.encoder();
    try b.beginKey();
    try ke.writeText("b");
    b.beginValue();
    try ke.writeUint(2);
    try b.beginKey();
    try ke.writeText("a");
    b.beginValue();
    try ke.writeUint(1);
    try b.beginKey();
    try ke.writeInt(-1);
    b.beginValue();
    try ke.writeNull();
    var buf: [16]u8 = undefined;
    var out = Encoder.initFixed(&buf);
    try b.finish(&out);
    try testing.expectEqualSlices(u8, &.{ 0xa3, 0x20, 0xf6, 0x61, 'a', 0x01, 0x61, 'b', 0x02 }, buf[0..out.len]);

    b.reset();
    try b.beginKey();
    try ke.writeFloat(0.0);
    b.beginValue();
    try ke.writeNull();
    try b.beginKey();
    try ke.writeFloat(-0.0);
    b.beginValue();
    try ke.writeNull();
    out = Encoder.initFixed(&buf);
    try testing.expectError(error.DuplicateMapKey, b.finish(&out));

    b.reset();
    try b.beginKey();
    try ke.writeEncoded(&.{0x1c});
    b.beginValue();
    try ke.writeNull();
    out = Encoder.initFixed(&buf);
    try testing.expectError(error.InvalidEncodedItem, b.finish(&out));
}

fn encodeAndFree(gpa: Allocator, value: Value) !void {
    const bytes = try encodeValueAlloc(gpa, value);
    gpa.free(bytes);
}

test "encoding releases every allocation on failure" {
    var inner = [_]Value.Entry{
        .{ .key = .{ .float = -0.0 }, .value = .{ .text = "z" } },
        .{ .key = .{ .integer = 1 }, .value = .null },
    };
    var items = [_]Value{ .{ .map = &inner }, .{ .integer = 7 } };
    var entries = [_]Value.Entry{
        .{ .key = .{ .text = "b" }, .value = .{ .array = &items } },
        .{ .key = .{ .map = &inner }, .value = .{ .bytes = "x" } },
        .{ .key = .{ .text = "a" }, .value = .{ .float = 1.5 } },
    };
    try testing.checkAllAllocationFailures(testing.allocator, encodeAndFree, .{Value{ .map = &entries }});
}
