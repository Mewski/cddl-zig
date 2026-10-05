//! Bounds-checked pull decoder for strict CBOR (RFC 8949).
//!
//! The decoder accepts every well-formed, valid encoding by default, including
//! nonpreferred arguments, indefinite lengths, and wider-than-needed floats.
//! `DecodeOptions.require_deterministic` restricts input to core deterministic
//! encoding (RFC 8949 Section 4.2.1). Duplicate map keys are always rejected
//! using generic data model equivalence (RFC 8949 Section 5.6.1).
//!
//! Every allocation goes through `Decoder.allocator()`, which charges a cumulative budget
//! and forwards to the caller's allocator. Results are owned by the caller and
//! freed with the caller's allocator; on error, everything allocated by a
//! runtime call has already been released.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const head = @import("head.zig");
const float = @import("float.zig");
const canonical = @import("canonical.zig");
const encoder = @import("encoder.zig");
const Value = @import("value.zig").Value;

const Head = head.Head;
const maxInt = std.math.maxInt;

pub const DecodeError = errors.DecodeError;

pub const Limits = struct {
    /// Maximum nesting of arrays, maps, and tags.
    max_depth: u32 = 64,
    /// Maximum number of data items, counting container and tag heads.
    max_items: u64 = 1 << 20,
    /// Maximum length of one byte or text string, summed over chunks.
    max_string_bytes: u64 = 16 << 20,
    /// Maximum cumulative bytes allocated through `Decoder.allocator()` during one
    /// decode. Frees and shrinks do not refund the budget.
    max_allocation_bytes: u64 = 64 << 20,
    /// Maximum work units: bytes examined plus map-key sorting and canonicalization cost.
    max_work: u64 = 1 << 28,
};

pub const DecodeOptions = struct {
    limits: Limits = .{},
    /// Reject input that is not in core deterministic encoding.
    require_deterministic: bool = false,
};

/// Classification of the next data item.
pub const Kind = enum {
    unsigned,
    negative,
    bytes,
    text,
    array,
    map,
    tag,
    false,
    true,
    null,
    undefined,
    simple,
    float16,
    float32,
    float64,
};

pub const Float = struct {
    width: float.Width,
    value: f64,
};

/// Half-open byte range of the input.
pub const Span = struct {
    start: usize,
    end: usize,
};

/// A decoded string. Definite-length strings borrow the input; indefinite-length
/// strings are concatenated into an allocation owned by the caller.
pub const StringRef = struct {
    bytes: []const u8,
    owned: bool,

    pub fn deinit(s: StringRef, gpa: Allocator) void {
        if (s.owned) gpa.free(s.bytes);
    }
};

pub const Array = struct {
    /// Offset of the array head.
    start: usize,
    /// Declared element count; null for indefinite length.
    count: ?u64,
    remaining: u64,
    done: bool = false,
};

const KeyRef = struct {
    offset: usize,
    len: usize,
    in_scratch: bool,
};

const inline_key_capacity = 8;

/// Iteration state of one map. Release with `Decoder.endMap`, or `deinit` on error paths.
pub const Map = struct {
    /// Offset of the map head.
    start: usize,
    /// Declared entry count; null for indefinite length.
    count: ?u64,
    remaining: u64,
    done: bool = false,
    prev_key: ?Span = null,
    key_count: usize = 0,
    inline_keys: [inline_key_capacity]KeyRef = undefined,
    heap_keys: std.ArrayList(KeyRef) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    has_scratch_keys: bool = false,

    /// Releases key-tracking storage. Safe to call more than once.
    pub fn deinit(m: *Map, d: *Decoder) void {
        const alloc = d.allocator();
        m.heap_keys.deinit(alloc);
        m.scratch.deinit(alloc);
        m.heap_keys = .empty;
        m.scratch = .empty;
    }

    fn keys(m: *Map) []KeyRef {
        if (m.heap_keys.items.len != 0) return m.heap_keys.items;
        return m.inline_keys[0..m.key_count];
    }

    fn pushKey(m: *Map, alloc: Allocator, ref: KeyRef) Allocator.Error!void {
        if (m.heap_keys.items.len == 0) {
            if (m.key_count < inline_key_capacity) {
                m.inline_keys[m.key_count] = ref;
                m.key_count += 1;
                return;
            }
            try m.heap_keys.ensureTotalCapacity(alloc, inline_key_capacity * 2);
            m.heap_keys.appendSliceAssumeCapacity(m.inline_keys[0..m.key_count]);
        }
        try m.heap_keys.append(alloc, ref);
        m.key_count += 1;
    }

    fn keyBytes(m: *const Map, input: []const u8, ref: KeyRef) []const u8 {
        const source = if (ref.in_scratch) m.scratch.items else input;
        return source[ref.offset..][0..ref.len];
    }
};

/// A consumed map key.
pub const MapKey = struct {
    /// Raw encoding in the input.
    span: Span,
    /// Equivalence form of the key: core deterministic encoding with -0.0 folded
    /// to 0.0 and unsigned NaN. Valid until the next key of the same map is read.
    canonical: []const u8,

    /// Compares against the core deterministic encoding of a key.
    pub fn isEncoded(k: MapKey, encoded: []const u8) bool {
        return std.mem.eql(u8, k.canonical, encoded);
    }

    pub fn isText(k: MapKey, text: []const u8) bool {
        return k.isString(.text, text);
    }

    pub fn isBytes(k: MapKey, bytes: []const u8) bool {
        return k.isString(.bytes, bytes);
    }

    pub fn isInt(k: MapKey, value: i65) bool {
        var buf: [head.max_len]u8 = undefined;
        const encoded = if (value >= 0)
            head.encode(&buf, .unsigned, @intCast(value))
        else
            head.encode(&buf, .negative, @intCast(-1 - value));
        return std.mem.eql(u8, k.canonical, encoded);
    }

    fn isString(k: MapKey, major: head.Major, s: []const u8) bool {
        var buf: [head.max_len]u8 = undefined;
        const h = head.encode(&buf, major, s.len);
        if (k.canonical.len != h.len + s.len) return false;
        return std.mem.eql(u8, k.canonical[0..h.len], h) and std.mem.eql(u8, k.canonical[h.len..], s);
    }
};

/// Decoder position and counters for backtracking. Work is never restored.
pub const Checkpoint = struct {
    pos: usize,
    depth: u32,
    items: u64,
    replay_end: usize,
};

const StringScan = struct {
    total: usize,
    definite: ?[]const u8,
    chunks_start: usize,
};

pub const Decoder = struct {
    gpa: Allocator,
    input: []const u8,
    options: DecodeOptions,
    pos: usize = 0,
    depth: u32 = 0,
    items: u64 = 0,
    work: u64 = 0,
    allocated: usize = 0,
    allocation_limit_hit: bool = false,
    /// Items before this offset were already counted and are being re-read.
    replay_end: usize = 0,
    /// Input offset associated with the most recent error.
    error_offset: usize = 0,

    pub fn init(gpa: Allocator, input: []const u8, options: DecodeOptions) Decoder {
        return .{ .gpa = gpa, .input = input, .options = options };
    }

    /// Budgeted allocator for decoded storage. Memory it returns may be freed
    /// with the caller's allocator after decoding. The budget is cumulative:
    /// freeing or shrinking through this allocator never refunds it.
    pub fn allocator(d: *Decoder) Allocator {
        return .{ .ptr = d, .vtable = &budget_vtable };
    }

    /// Converts an `error.OutOfMemory` from `allocator()` into the precise error.
    pub fn allocationFailure(d: *Decoder) DecodeError {
        if (d.allocation_limit_hit) {
            d.allocation_limit_hit = false;
            return d.failAt(d.pos, error.AllocationLimitExceeded);
        }
        d.error_offset = d.pos;
        return error.OutOfMemory;
    }

    /// Records `offset` as the error location and returns `err`.
    pub fn failAt(d: *Decoder, offset: usize, err: DecodeError) DecodeError {
        d.error_offset = offset;
        return err;
    }

    pub fn atEnd(d: *const Decoder) bool {
        return d.pos == d.input.len;
    }

    /// Requires that the whole input has been consumed.
    pub fn finish(d: *Decoder) DecodeError!void {
        std.debug.assert(d.depth == 0);
        if (d.pos != d.input.len) return d.failAt(d.pos, error.TrailingBytes);
    }

    pub fn save(d: *const Decoder) Checkpoint {
        return .{ .pos = d.pos, .depth = d.depth, .items = d.items, .replay_end = d.replay_end };
    }

    pub fn restore(d: *Decoder, cp: Checkpoint) void {
        d.pos = cp.pos;
        d.depth = cp.depth;
        d.items = cp.items;
        d.replay_end = cp.replay_end;
    }

    /// Enters one nesting level; pair with `leave`.
    pub fn enter(d: *Decoder, at: usize) DecodeError!void {
        if (d.depth >= d.options.limits.max_depth) return d.failAt(at, error.DepthLimitExceeded);
        d.depth += 1;
    }

    pub fn leave(d: *Decoder) void {
        std.debug.assert(d.depth > 0);
        d.depth -= 1;
    }

    pub fn chargeWork(d: *Decoder, units: u64) DecodeError!void {
        d.work = std.math.add(u64, d.work, units) catch maxInt(u64);
        if (d.work > d.options.limits.max_work) return d.failAt(d.pos, error.WorkLimitExceeded);
    }

    // Heads

    fn parseAt(d: *Decoder, pos: usize) DecodeError!Head {
        return head.parse(d.input, pos) catch |err| return d.failAt(pos, err);
    }

    /// Parses the next head without consuming it; a break is malformed here.
    fn peekItem(d: *Decoder) DecodeError!Head {
        const h = try d.parseAt(d.pos);
        if (h.isBreak()) return d.failAt(d.pos, error.UnexpectedBreak);
        return h;
    }

    fn advance(d: *Decoder, n: usize) DecodeError!void {
        try d.chargeWork(n);
        d.pos += n;
    }

    /// Consumes a peeked item head, enforcing determinism and the item limit.
    fn commitHead(d: *Decoder, h: Head) DecodeError!void {
        const at = d.pos;
        if (d.options.require_deterministic) try d.checkDeterministic(h, at);
        if (at >= d.replay_end) {
            if (d.items >= d.options.limits.max_items) return d.failAt(at, error.ItemLimitExceeded);
            d.items += 1;
        }
        try d.advance(h.len);
    }

    fn checkDeterministic(d: *Decoder, h: Head, at: usize) DecodeError!void {
        if (h.major == .simple) {
            const width = float.Width.fromInfo(h.info) orelse return;
            if (float.preferred(float.decode(.{ .width = width, .bits = h.arg })).width != width)
                return d.failAt(at, error.NonPreferredFloat);
            return;
        }
        if (h.isIndefinite()) return d.failAt(at, error.IndefiniteLengthNotAllowed);
        if (!h.hasPreferredArgument()) return d.failAt(at, error.NonPreferredArgument);
    }

    fn mismatch(d: *Decoder) DecodeError {
        return d.failAt(d.pos, error.TypeMismatch);
    }

    /// Classifies the next data item without consuming it.
    pub fn peekKind(d: *Decoder) DecodeError!Kind {
        const h = try d.peekItem();
        return switch (h.major) {
            .unsigned => .unsigned,
            .negative => .negative,
            .bytes => .bytes,
            .text => .text,
            .array => .array,
            .map => .map,
            .tag => .tag,
            .simple => switch (h.info) {
                20 => .false,
                21 => .true,
                22 => .null,
                23 => .undefined,
                25 => .float16,
                26 => .float32,
                27 => .float64,
                else => .simple,
            },
        };
    }

    /// Tag number of the next item if it is tagged, without consuming it.
    pub fn peekTag(d: *Decoder) DecodeError!?u64 {
        const h = try d.peekItem();
        return if (h.major == .tag) h.arg else null;
    }

    // Scalars

    pub fn readUint(d: *Decoder) DecodeError!u64 {
        const h = try d.peekItem();
        if (h.major != .unsigned) return d.mismatch();
        try d.commitHead(h);
        return h.arg;
    }

    /// Reads a negative integer and returns its argument n, denoting -1 - n.
    pub fn readNegative(d: *Decoder) DecodeError!u64 {
        const h = try d.peekItem();
        if (h.major != .negative) return d.mismatch();
        try d.commitHead(h);
        return h.arg;
    }

    pub fn readInt(d: *Decoder) DecodeError!i65 {
        const h = try d.peekItem();
        const value: i65 = switch (h.major) {
            .unsigned => h.arg,
            .negative => -1 - @as(i65, h.arg),
            else => return d.mismatch(),
        };
        try d.commitHead(h);
        return value;
    }

    /// Reads an integer that must fit `T`; nothing is consumed on mismatch.
    pub fn readIntAs(d: *Decoder, comptime T: type) DecodeError!T {
        const h = try d.peekItem();
        const value: i65 = switch (h.major) {
            .unsigned => h.arg,
            .negative => -1 - @as(i65, h.arg),
            else => return d.mismatch(),
        };
        const result = std.math.cast(T, value) orelse return d.failAt(d.pos, error.IntegerOutOfRange);
        try d.commitHead(h);
        return result;
    }

    pub fn readBool(d: *Decoder) DecodeError!bool {
        const h = try d.peekItem();
        if (h.major != .simple or (h.info != 20 and h.info != 21)) return d.mismatch();
        try d.commitHead(h);
        return h.info == 21;
    }

    pub fn readNull(d: *Decoder) DecodeError!void {
        const h = try d.peekItem();
        if (h.major != .simple or h.info != 22) return d.mismatch();
        try d.commitHead(h);
    }

    pub fn readUndefined(d: *Decoder) DecodeError!void {
        const h = try d.peekItem();
        if (h.major != .simple or h.info != 23) return d.mismatch();
        try d.commitHead(h);
    }

    /// Reads any simple value (major type 7 other than floats), returning its number.
    pub fn readSimple(d: *Decoder) DecodeError!u8 {
        const h = try d.peekItem();
        if (h.major != .simple or h.info > 24) return d.mismatch();
        try d.commitHead(h);
        return @intCast(h.arg);
    }

    /// Reads a float of any width as f64.
    pub fn readFloat(d: *Decoder) DecodeError!f64 {
        return (try d.readFloatWidth()).value;
    }

    /// Reads a float and reports the width it was encoded with.
    pub fn readFloatWidth(d: *Decoder) DecodeError!Float {
        const h = try d.peekItem();
        if (h.major != .simple) return d.mismatch();
        const width = float.Width.fromInfo(h.info) orelse return d.mismatch();
        try d.commitHead(h);
        return .{ .width = width, .value = float.decode(.{ .width = width, .bits = h.arg }) };
    }

    pub fn readTag(d: *Decoder) DecodeError!u64 {
        const h = try d.peekItem();
        if (h.major != .tag) return d.mismatch();
        try d.commitHead(h);
        return h.arg;
    }

    /// Reads a tag head and enters a nesting level for its content; pair with `endTag`.
    pub fn beginTag(d: *Decoder) DecodeError!u64 {
        const at = d.pos;
        const number = try d.readTag();
        try d.enter(at);
        return number;
    }

    pub fn endTag(d: *Decoder) void {
        d.leave();
    }

    // Strings

    pub fn readBytesRef(d: *Decoder) DecodeError!StringRef {
        return d.readStringRef(.bytes);
    }

    pub fn readTextRef(d: *Decoder) DecodeError!StringRef {
        return d.readStringRef(.text);
    }

    /// Reads a byte string into memory owned by the caller.
    pub fn readBytesAlloc(d: *Decoder) DecodeError![]u8 {
        return d.readStringAlloc(.bytes);
    }

    /// Reads a text string into memory owned by the caller.
    pub fn readTextAlloc(d: *Decoder) DecodeError![]u8 {
        return d.readStringAlloc(.text);
    }

    fn readStringRef(d: *Decoder, major: head.Major) DecodeError!StringRef {
        const h = try d.peekItem();
        if (h.major != major) return d.mismatch();
        const s = try d.scanString(h);
        if (s.definite) |bytes| return .{ .bytes = bytes, .owned = false };
        return .{ .bytes = try d.gatherAlloc(s), .owned = true };
    }

    fn readStringAlloc(d: *Decoder, major: head.Major) DecodeError![]u8 {
        const h = try d.peekItem();
        if (h.major != major) return d.mismatch();
        const s = try d.scanString(h);
        if (s.definite) |bytes| return d.allocator().dupe(u8, bytes) catch return d.allocationFailure();
        return d.gatherAlloc(s);
    }

    /// Consumes and validates a string whose head `h` is next in the input.
    fn scanString(d: *Decoder, h: Head) DecodeError!StringScan {
        const at = d.pos;
        try d.commitHead(h);
        if (!h.isIndefinite()) {
            const bytes = try d.takeContent(at, h);
            return .{ .total = bytes.len, .definite = bytes, .chunks_start = d.pos };
        }
        const chunks_start = d.pos;
        var total: u64 = 0;
        while (true) {
            const chunk_at = d.pos;
            const c = try d.parseAt(chunk_at);
            if (c.isBreak()) {
                try d.advance(1);
                break;
            }
            if (c.major != h.major or c.isIndefinite()) return d.failAt(chunk_at, error.InvalidIndefiniteStringChunk);
            try d.advance(c.len);
            const bytes = try d.takeContent(chunk_at, c);
            total += bytes.len;
            if (total > d.options.limits.max_string_bytes) return d.failAt(chunk_at, error.StringLengthLimitExceeded);
        }
        return .{ .total = @intCast(total), .definite = null, .chunks_start = chunks_start };
    }

    /// Consumes the content of a definite string or chunk whose head is consumed.
    fn takeContent(d: *Decoder, at: usize, h: Head) DecodeError![]const u8 {
        if (h.arg > d.input.len - d.pos) return d.failAt(at, error.UnexpectedEndOfInput);
        if (h.arg > d.options.limits.max_string_bytes) return d.failAt(at, error.StringLengthLimitExceeded);
        const len: usize = @intCast(h.arg);
        try d.chargeWork(len);
        const bytes = d.input[d.pos..][0..len];
        if (h.major == .text and !std.unicode.utf8ValidateSlice(bytes)) return d.failAt(at, error.InvalidUtf8);
        d.pos += len;
        return bytes;
    }

    fn gatherAlloc(d: *Decoder, s: StringScan) DecodeError![]u8 {
        const out = d.allocator().alloc(u8, s.total) catch return d.allocationFailure();
        var pos = s.chunks_start;
        var written: usize = 0;
        while (d.input[pos] != head.break_byte) {
            // Chunks were validated by scanString.
            const c = head.parse(d.input, pos) catch unreachable;
            const len: usize = @intCast(c.arg);
            const start = pos + c.len;
            @memcpy(out[written..][0..len], d.input[start..][0..len]);
            written += len;
            pos = start + len;
        }
        return out;
    }

    // Containers

    fn checkContainerLen(d: *Decoder, at: usize, count: u64, items_per_entry: u64) DecodeError!void {
        const min_items = std.math.mul(u64, count, items_per_entry) catch return d.failAt(at, error.UnexpectedEndOfInput);
        if (min_items > d.input.len - d.pos) return d.failAt(at, error.UnexpectedEndOfInput);
        if (at >= d.replay_end and min_items > d.options.limits.max_items - d.items)
            return d.failAt(at, error.ItemLimitExceeded);
    }

    /// Reads an array head and enters a nesting level; finish with `endArray`.
    pub fn beginArray(d: *Decoder) DecodeError!Array {
        const at = d.pos;
        const h = try d.peekItem();
        if (h.major != .array) return d.mismatch();
        try d.commitHead(h);
        try d.enter(at);
        if (h.isIndefinite()) return .{ .start = at, .count = null, .remaining = 0 };
        try d.checkContainerLen(at, h.arg, 1);
        return .{ .start = at, .count = h.arg, .remaining = h.arg };
    }

    /// Advances to the next element; false once the array is exhausted.
    pub fn nextArrayItem(d: *Decoder, a: *Array) DecodeError!bool {
        return d.nextEntry(a.count, &a.remaining, &a.done);
    }

    /// Whether the array has no further elements, without consuming anything.
    pub fn arrayAtEnd(d: *Decoder, a: *const Array) DecodeError!bool {
        if (a.done) return true;
        if (a.count != null) return a.remaining == 0;
        if (d.pos >= d.input.len) return d.failAt(d.pos, error.UnexpectedEndOfInput);
        return d.input[d.pos] == head.break_byte;
    }

    /// Requires the array to be exhausted and leaves its nesting level.
    pub fn endArray(d: *Decoder, a: *Array) DecodeError!void {
        try d.finishEntries(a.count, a.remaining, &a.done);
        d.leave();
    }

    /// Reads a map head and enters a nesting level; finish with `endMap`.
    /// On error paths call `Map.deinit`.
    pub fn beginMap(d: *Decoder) DecodeError!Map {
        const at = d.pos;
        const h = try d.peekItem();
        if (h.major != .map) return d.mismatch();
        try d.commitHead(h);
        try d.enter(at);
        if (h.isIndefinite()) return .{ .start = at, .count = null, .remaining = 0 };
        try d.checkContainerLen(at, h.arg, 2);
        return .{ .start = at, .count = h.arg, .remaining = h.arg };
    }

    /// Consumes and registers the next key, or returns null once the map is
    /// exhausted. The value must be read before requesting the next key.
    pub fn nextMapKey(d: *Decoder, m: *Map) DecodeError!?MapKey {
        if (!try d.nextEntry(m.count, &m.remaining, &m.done)) return null;
        const start = d.pos;
        try d.skip();
        return try d.registerKey(m, start, d.pos);
    }

    /// Rewinds to the start of `key` so it can be decoded with typed reads.
    /// Items inside the key are not counted twice.
    pub fn rereadKey(d: *Decoder, key: MapKey) void {
        d.pos = key.span.start;
        d.replay_end = @max(d.replay_end, key.span.end);
    }

    /// Requires the map to be exhausted, rejects duplicate keys, releases key
    /// storage, and leaves its nesting level.
    pub fn endMap(d: *Decoder, m: *Map) DecodeError!void {
        try d.finishEntries(m.count, m.remaining, &m.done);
        try d.checkDuplicateKeys(m);
        m.deinit(d);
        d.leave();
    }

    fn nextEntry(d: *Decoder, count: ?u64, remaining: *u64, done: *bool) DecodeError!bool {
        if (done.*) return false;
        if (count != null) {
            if (remaining.* == 0) {
                done.* = true;
                return false;
            }
            remaining.* -= 1;
            return true;
        }
        if (d.pos >= d.input.len) return d.failAt(d.pos, error.UnexpectedEndOfInput);
        if (d.input[d.pos] == head.break_byte) {
            try d.advance(1);
            done.* = true;
            return false;
        }
        return true;
    }

    fn finishEntries(d: *Decoder, count: ?u64, remaining: u64, done: *bool) DecodeError!void {
        if (done.*) return;
        if (count != null) {
            if (remaining != 0) return d.failAt(d.pos, error.LengthMismatch);
            done.* = true;
            return;
        }
        if (d.pos >= d.input.len) return d.failAt(d.pos, error.UnexpectedEndOfInput);
        if (d.input[d.pos] != head.break_byte) return d.failAt(d.pos, error.LengthMismatch);
        try d.advance(1);
        done.* = true;
    }

    fn registerKey(d: *Decoder, m: *Map, start: usize, end: usize) DecodeError!MapKey {
        const raw = d.input[start..end];
        if (d.options.require_deterministic) {
            if (m.prev_key) |prev| {
                try d.chargeWork(@min(raw.len, prev.end - prev.start));
                switch (std.mem.order(u8, d.input[prev.start..prev.end], raw)) {
                    .lt => {},
                    .eq => return d.failAt(start, error.DuplicateMapKey),
                    .gt => return d.failAt(start, error.UnsortedMapKeys),
                }
            }
            m.prev_key = .{ .start = start, .end = end };
        }
        try d.chargeWork(raw.len);
        const ref: KeyRef = if (canonical.isKeyCanonical(raw))
            .{ .offset = start, .len = raw.len, .in_scratch = false }
        else
            try d.canonicalizeKey(m, raw);
        m.pushKey(d.allocator(), ref) catch return d.allocationFailure();
        return .{ .span = .{ .start = start, .end = end }, .canonical = m.keyBytes(d.input, ref) };
    }

    fn canonicalizeKey(d: *Decoder, m: *Map, raw: []const u8) DecodeError!KeyRef {
        const alloc = d.allocator();
        var sub = Decoder.init(alloc, raw, .{ .limits = .{
            .max_depth = d.options.limits.max_depth,
            .max_items = maxInt(u64),
            .max_string_bytes = maxInt(u64),
            .max_allocation_bytes = maxInt(u64),
            .max_work = maxInt(u64),
        } });
        const value = sub.readValue() catch |err| switch (err) {
            error.OutOfMemory => return d.allocationFailure(),
            else => return d.failAt(d.pos, err),
        };
        defer value.deinit(alloc);
        try d.chargeWork(sub.work);

        const offset = m.scratch.items.len;
        var out = encoder.Encoder.initList(alloc, &m.scratch);
        out.writeValueWithMode(alloc, value, .key_equivalence) catch |err| switch (err) {
            error.OutOfMemory => return d.allocationFailure(),
            error.DuplicateMapKey => return d.failAt(d.pos, error.DuplicateMapKey),
            error.InvalidUtf8 => return d.failAt(d.pos, error.InvalidUtf8),
            // A list sink cannot fail on output, and decoded values hold no invalid simple values.
            else => unreachable,
        };
        m.has_scratch_keys = true;
        return .{ .offset = offset, .len = m.scratch.items.len - offset, .in_scratch = true };
    }

    fn checkDuplicateKeys(d: *Decoder, m: *Map) DecodeError!void {
        const refs = m.keys();
        if (refs.len < 2) return;
        // Deterministic input already has strictly increasing raw keys, which
        // equal their equivalence forms unless a key needed canonicalization.
        if (d.options.require_deterministic and !m.has_scratch_keys) return;

        var total: u64 = 0;
        for (refs) |r| total += r.len;
        const rounds: u64 = std.math.log2_int_ceil(usize, refs.len);
        try d.chargeWork(std.math.mul(u64, total, rounds) catch maxInt(u64));

        const order: KeyOrder = .{ .map = m, .input = d.input };
        std.mem.sortUnstable(KeyRef, refs, order, KeyOrder.lessThan);
        for (refs[1..], refs[0 .. refs.len - 1]) |b, a| {
            if (std.mem.eql(u8, m.keyBytes(d.input, a), m.keyBytes(d.input, b)))
                return d.failAt(m.start, error.DuplicateMapKey);
        }
    }

    const KeyOrder = struct {
        map: *const Map,
        input: []const u8,

        fn lessThan(ctx: KeyOrder, a: KeyRef, b: KeyRef) bool {
            return std.mem.order(u8, ctx.map.keyBytes(ctx.input, a), ctx.map.keyBytes(ctx.input, b)) == .lt;
        }
    };

    // Generic items

    /// Consumes and fully validates the next data item.
    pub fn skip(d: *Decoder) DecodeError!void {
        const at = d.pos;
        const h = try d.peekItem();
        switch (h.major) {
            .unsigned, .negative, .simple => try d.commitHead(h),
            .bytes, .text => _ = try d.scanString(h),
            .array => {
                var a = try d.beginArray();
                while (try d.nextArrayItem(&a)) try d.skip();
                try d.endArray(&a);
            },
            .map => {
                var m = try d.beginMap();
                defer m.deinit(d);
                while (try d.nextEntry(m.count, &m.remaining, &m.done)) {
                    const key_start = d.pos;
                    try d.skip();
                    _ = try d.registerKey(&m, key_start, d.pos);
                    try d.skip();
                }
                try d.endMap(&m);
            },
            .tag => {
                try d.commitHead(h);
                try d.enter(at);
                try d.skip();
                d.leave();
            },
        }
    }

    /// Decodes the next data item into a `Value` owned by the caller.
    pub fn readValue(d: *Decoder) DecodeError!Value {
        const at = d.pos;
        const h = try d.peekItem();
        switch (h.major) {
            .unsigned => {
                try d.commitHead(h);
                return .{ .integer = h.arg };
            },
            .negative => {
                try d.commitHead(h);
                return .{ .integer = -1 - @as(i65, h.arg) };
            },
            .bytes => return .{ .bytes = try d.readStringAlloc(.bytes) },
            .text => return .{ .text = try d.readStringAlloc(.text) },
            .array => return .{ .array = try d.readArrayValue() },
            .map => return .{ .map = try d.readMapValue() },
            .tag => {
                try d.commitHead(h);
                try d.enter(at);
                const alloc = d.allocator();
                const content = alloc.create(Value) catch return d.allocationFailure();
                errdefer alloc.destroy(content);
                content.* = try d.readValue();
                d.leave();
                return .{ .tag = .{ .number = h.arg, .content = content } };
            },
            .simple => {
                try d.commitHead(h);
                return switch (h.info) {
                    20 => .{ .boolean = false },
                    21 => .{ .boolean = true },
                    22 => .null,
                    23 => .undefined,
                    25, 26, 27 => .{ .float = float.decode(.{ .width = float.Width.fromInfo(h.info).?, .bits = h.arg }) },
                    else => .{ .simple = @intCast(h.arg) },
                };
            },
        }
    }

    fn readArrayValue(d: *Decoder) DecodeError![]Value {
        const alloc = d.allocator();
        var a = try d.beginArray();
        var list: std.ArrayList(Value) = .empty;
        errdefer {
            for (list.items) |item| item.deinit(alloc);
            list.deinit(alloc);
        }
        if (a.count) |n| list.ensureTotalCapacityPrecise(alloc, @intCast(n)) catch return d.allocationFailure();
        while (try d.nextArrayItem(&a)) {
            const item = try d.readValue();
            list.append(alloc, item) catch {
                item.deinit(alloc);
                return d.allocationFailure();
            };
        }
        try d.endArray(&a);
        return list.toOwnedSlice(alloc) catch return d.allocationFailure();
    }

    fn readMapValue(d: *Decoder) DecodeError![]Value.Entry {
        const alloc = d.allocator();
        var m = try d.beginMap();
        defer m.deinit(d);
        var list: std.ArrayList(Value.Entry) = .empty;
        errdefer {
            for (list.items) |entry| {
                entry.key.deinit(alloc);
                entry.value.deinit(alloc);
            }
            list.deinit(alloc);
        }
        if (m.count) |n| list.ensureTotalCapacityPrecise(alloc, @intCast(n)) catch return d.allocationFailure();
        while (try d.nextEntry(m.count, &m.remaining, &m.done)) {
            const key_start = d.pos;
            const key = try d.readValue();
            _ = d.registerKey(&m, key_start, d.pos) catch |err| {
                key.deinit(alloc);
                return err;
            };
            const value = d.readValue() catch |err| {
                key.deinit(alloc);
                return err;
            };
            list.append(alloc, .{ .key = key, .value = value }) catch {
                key.deinit(alloc);
                value.deinit(alloc);
                return d.allocationFailure();
            };
        }
        try d.endMap(&m);
        return list.toOwnedSlice(alloc) catch return d.allocationFailure();
    }

    // Allocation budget. Charges are cumulative because the backing allocator
    // may ignore frees and shrinks (an arena does), so only a request the
    // backing allocator rejects is refunded.

    fn reserve(d: *Decoder, n: usize) bool {
        const next = std.math.add(usize, d.allocated, n) catch {
            d.allocation_limit_hit = true;
            return false;
        };
        if (next > d.options.limits.max_allocation_bytes) {
            d.allocation_limit_hit = true;
            return false;
        }
        d.allocated = next;
        return true;
    }

    fn refundRejected(d: *Decoder, n: usize) void {
        d.allocated -= n;
    }

    const budget_vtable: Allocator.VTable = .{
        .alloc = budgetAlloc,
        .resize = budgetResize,
        .remap = budgetRemap,
        .free = budgetFree,
    };

    fn budgetAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const d: *Decoder = @ptrCast(@alignCast(ctx));
        if (!d.reserve(len)) return null;
        return d.gpa.rawAlloc(len, alignment, ret_addr) orelse {
            d.refundRejected(len);
            return null;
        };
    }

    fn budgetResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const d: *Decoder = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) return d.gpa.rawResize(memory, alignment, new_len, ret_addr);
        const extra = new_len - memory.len;
        if (!d.reserve(extra)) return false;
        if (d.gpa.rawResize(memory, alignment, new_len, ret_addr)) return true;
        d.refundRejected(extra);
        return false;
    }

    fn budgetRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const d: *Decoder = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) return d.gpa.rawRemap(memory, alignment, new_len, ret_addr);
        const extra = new_len - memory.len;
        if (!d.reserve(extra)) return null;
        return d.gpa.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            d.refundRejected(extra);
            return null;
        };
    }

    fn budgetFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const d: *Decoder = @ptrCast(@alignCast(ctx));
        d.gpa.rawFree(memory, alignment, ret_addr);
    }
};

/// Decodes exactly one data item spanning all of `input`.
pub fn decodeValue(gpa: Allocator, input: []const u8, options: DecodeOptions) DecodeError!Value {
    var d = Decoder.init(gpa, input, options);
    const value = try d.readValue();
    errdefer value.deinit(gpa);
    try d.finish();
    return value;
}

/// Checks that `input` is exactly one well-formed, valid data item.
/// `gpa` backs temporary duplicate-key tracking only.
pub fn validate(gpa: Allocator, input: []const u8, options: DecodeOptions) DecodeError!void {
    var d = Decoder.init(gpa, input, options);
    try d.skip();
    try d.finish();
}

test "integers cover the full CBOR domain" {
    const cases = [_]struct { bytes: []const u8, value: i65 }{
        .{ .bytes = &.{0x00}, .value = 0 },
        .{ .bytes = &.{0x17}, .value = 23 },
        .{ .bytes = &.{ 0x18, 0x18 }, .value = 24 },
        .{ .bytes = &.{ 0x19, 0x03, 0xe8 }, .value = 1000 },
        .{ .bytes = &.{ 0x1a, 0x00, 0x0f, 0x42, 0x40 }, .value = 1000000 },
        .{ .bytes = &.{ 0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .value = maxInt(u64) },
        .{ .bytes = &.{0x20}, .value = -1 },
        .{ .bytes = &.{ 0x38, 0x63 }, .value = -100 },
        .{ .bytes = &.{ 0x39, 0x03, 0xe7 }, .value = -1000 },
        .{ .bytes = &.{ 0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .value = -18446744073709551616 },
    };
    for (cases) |c| {
        const value = try decodeValue(std.testing.allocator, c.bytes, .{});
        try std.testing.expectEqual(c.value, value.integer);
        var d = Decoder.init(std.testing.allocator, c.bytes, .{});
        try std.testing.expectEqual(c.value, try d.readInt());
        try d.finish();
    }
    var d = Decoder.init(std.testing.allocator, &.{ 0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .{});
    try std.testing.expectError(error.TypeMismatch, d.readUint());
    try std.testing.expectEqual(@as(u64, maxInt(u64)), try d.readNegative());
}

test "readIntAs checks the target range without consuming" {
    var d = Decoder.init(std.testing.allocator, &.{ 0x19, 0x01, 0x00, 0x38, 0x80 }, .{});
    try std.testing.expectError(error.IntegerOutOfRange, d.readIntAs(u8));
    try std.testing.expectEqual(@as(u16, 256), try d.readIntAs(u16));
    try std.testing.expectError(error.IntegerOutOfRange, d.readIntAs(i8));
    try std.testing.expectError(error.IntegerOutOfRange, d.readIntAs(u64));
    try std.testing.expectEqual(@as(i16, -129), try d.readIntAs(i16));
    try d.finish();
}

test "floats of every width decode bit-exactly" {
    const cases = [_]struct { bytes: []const u8, width: float.Width, bits: u64 }{
        .{ .bytes = &.{ 0xf9, 0x00, 0x00 }, .width = .half, .bits = 0 },
        .{ .bytes = &.{ 0xf9, 0x80, 0x00 }, .width = .half, .bits = 0x8000_0000_0000_0000 },
        .{ .bytes = &.{ 0xf9, 0x3c, 0x00 }, .width = .half, .bits = 0x3ff0_0000_0000_0000 },
        .{ .bytes = &.{ 0xf9, 0x7b, 0xff }, .width = .half, .bits = 0x40ef_fc00_0000_0000 },
        .{ .bytes = &.{ 0xf9, 0x00, 0x01 }, .width = .half, .bits = 0x3e70_0000_0000_0000 },
        .{ .bytes = &.{ 0xf9, 0x7c, 0x00 }, .width = .half, .bits = 0x7ff0_0000_0000_0000 },
        .{ .bytes = &.{ 0xf9, 0x7e, 0x00 }, .width = .half, .bits = 0x7ff8_0000_0000_0000 },
        .{ .bytes = &.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 }, .width = .single, .bits = 0x40f8_6a00_0000_0000 },
        .{ .bytes = &.{ 0xfa, 0x7f, 0x80, 0x00, 0x00 }, .width = .single, .bits = 0x7ff0_0000_0000_0000 },
        .{ .bytes = &.{ 0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a }, .width = .double, .bits = 0x3ff1_9999_9999_999a },
    };
    for (cases) |c| {
        var d = Decoder.init(std.testing.allocator, c.bytes, .{});
        const f = try d.readFloatWidth();
        try std.testing.expectEqual(c.width, f.width);
        try std.testing.expectEqual(c.bits, @as(u64, @bitCast(f.value)));
        try d.finish();
    }
}

test "indefinite strings and containers" {
    const gpa = std.testing.allocator;
    {
        const input = [_]u8{ 0x5f, 0x42, 0x01, 0x02, 0x43, 0x03, 0x04, 0x05, 0xff };
        var d = Decoder.init(gpa, &input, .{});
        const s = try d.readBytesRef();
        defer s.deinit(gpa);
        try std.testing.expect(s.owned);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, s.bytes);
        try d.finish();
    }
    {
        const value = try decodeValue(gpa, "\x7f\x65strea\x64ming\xff", .{});
        defer value.deinit(gpa);
        try std.testing.expectEqualStrings("streaming", value.text);
    }
    {
        const input: []const u8 = "\x64abcd";
        var d = Decoder.init(gpa, input, .{});
        const s = try d.readTextRef();
        try std.testing.expect(!s.owned);
        try std.testing.expectEqual(input.ptr + 1, s.bytes.ptr);
    }
    {
        const value = try decodeValue(gpa, &.{ 0x5f, 0xff }, .{});
        defer value.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), value.bytes.len);
    }
    {
        const value = try decodeValue(gpa, &.{ 0x9f, 0x01, 0x82, 0x02, 0x03, 0x9f, 0x04, 0x05, 0xff, 0xff }, .{});
        defer value.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 3), value.array.len);
        try std.testing.expectEqual(@as(i65, 5), value.array[2].array[1].integer);
    }
    {
        const value = try decodeValue(gpa, &.{ 0xbf, 0x61, 'a', 0x01, 0x61, 'b', 0x9f, 0x02, 0x03, 0xff, 0xff }, .{});
        defer value.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), value.map.len);
        try std.testing.expectEqualStrings("b", value.map[1].key.text);
        try std.testing.expectEqual(@as(i65, 3), value.map[1].value.array[1].integer);
    }
}

test "malformed, nondeterministic, and over-limit input is rejected with its offset" {
    const Rejection = struct {
        bytes: []const u8,
        err: DecodeError,
        offset: usize,

        fn expectAll(rejections: []const @This(), options: DecodeOptions) !void {
            for (rejections) |c| {
                var d = Decoder.init(std.testing.allocator, c.bytes, options);
                try std.testing.expectError(c.err, decodeAll(&d));
                try std.testing.expectEqual(c.offset, d.error_offset);
                try std.testing.expectError(c.err, validate(std.testing.allocator, c.bytes, options));
            }
        }

        fn decodeAll(d: *Decoder) DecodeError!void {
            const value = try d.readValue();
            defer value.deinit(d.gpa);
            try d.finish();
        }
    };

    try Rejection.expectAll(&.{
        .{ .bytes = &.{}, .err = error.UnexpectedEndOfInput, .offset = 0 },
        .{ .bytes = &.{0x18}, .err = error.UnexpectedEndOfInput, .offset = 0 },
        .{ .bytes = &.{ 0x1a, 0x01, 0x02 }, .err = error.UnexpectedEndOfInput, .offset = 0 },
        .{ .bytes = &.{0x1c}, .err = error.ReservedAdditionalInfo, .offset = 0 },
        .{ .bytes = &.{ 0x81, 0x1d }, .err = error.ReservedAdditionalInfo, .offset = 1 },
        .{ .bytes = &.{0x1f}, .err = error.InvalidIndefiniteLength, .offset = 0 },
        .{ .bytes = &.{ 0xdf, 0x00 }, .err = error.InvalidIndefiniteLength, .offset = 0 },
        .{ .bytes = &.{ 0xf8, 0x18 }, .err = error.InvalidSimpleValue, .offset = 0 },
        .{ .bytes = &.{0xff}, .err = error.UnexpectedBreak, .offset = 0 },
        .{ .bytes = &.{ 0x82, 0x01, 0xff }, .err = error.UnexpectedBreak, .offset = 2 },
        .{ .bytes = &.{ 0xbf, 0x01, 0xff }, .err = error.UnexpectedBreak, .offset = 2 },
        .{ .bytes = &.{ 0x5f, 0x00, 0xff }, .err = error.InvalidIndefiniteStringChunk, .offset = 1 },
        .{ .bytes = &.{ 0x5f, 0x5f, 0xff, 0xff }, .err = error.InvalidIndefiniteStringChunk, .offset = 1 },
        .{ .bytes = &.{ 0x7f, 0x41, 0x00, 0xff }, .err = error.InvalidIndefiniteStringChunk, .offset = 1 },
        .{ .bytes = &.{ 0x5f, 0x41 }, .err = error.UnexpectedEndOfInput, .offset = 1 },
        .{ .bytes = &.{ 0x5f, 0x41, 0x00 }, .err = error.UnexpectedEndOfInput, .offset = 3 },
        .{ .bytes = &.{ 0x9f, 0x01 }, .err = error.UnexpectedEndOfInput, .offset = 2 },
        .{ .bytes = &.{0x81}, .err = error.UnexpectedEndOfInput, .offset = 0 },
        .{ .bytes = &.{ 0xa1, 0x01 }, .err = error.UnexpectedEndOfInput, .offset = 0 },
        .{ .bytes = &.{ 0x42, 0x01 }, .err = error.UnexpectedEndOfInput, .offset = 0 },
        .{ .bytes = &.{0xc0}, .err = error.UnexpectedEndOfInput, .offset = 1 },
        .{ .bytes = &.{ 0x00, 0x00 }, .err = error.TrailingBytes, .offset = 1 },
        .{ .bytes = &.{ 0x62, 0xc3, 0x28 }, .err = error.InvalidUtf8, .offset = 0 },
        .{ .bytes = &.{ 0x63, 0xed, 0xa0, 0x80 }, .err = error.InvalidUtf8, .offset = 0 },
        .{ .bytes = &.{ 0x7f, 0x61, 0xc3, 0x61, 0xa9, 0xff }, .err = error.InvalidUtf8, .offset = 1 },
        .{ .bytes = &.{ 0xa2, 0x01, 0x00, 0x01, 0x00 }, .err = error.DuplicateMapKey, .offset = 0 },
        .{ .bytes = &.{ 0xa2, 0x01, 0x00, 0x18, 0x01, 0x00 }, .err = error.DuplicateMapKey, .offset = 0 },
        .{ .bytes = &.{ 0xa2, 0xf9, 0x00, 0x00, 0x00, 0xf9, 0x80, 0x00, 0x00 }, .err = error.DuplicateMapKey, .offset = 0 },
        .{ .bytes = &.{ 0xa2, 0xf9, 0x7e, 0x00, 0x00, 0xfb, 0xff, 0xf8, 0, 0, 0, 0, 0, 0, 0x00 }, .err = error.DuplicateMapKey, .offset = 0 },
        .{ .bytes = &.{ 0xa2, 0x62, 'a', 'b', 0x00, 0x7f, 0x61, 'a', 0x61, 'b', 0xff, 0x00 }, .err = error.DuplicateMapKey, .offset = 0 },
        .{ .bytes = &.{ 0xa2, 0xa1, 0x01, 0x02, 0x00, 0xbf, 0x01, 0x02, 0xff, 0x00 }, .err = error.DuplicateMapKey, .offset = 0 },
        .{ .bytes = &.{ 0xa1, 0xa2, 0x01, 0x00, 0x01, 0x00, 0x00 }, .err = error.DuplicateMapKey, .offset = 1 },
    }, .{});

    const deterministic: DecodeOptions = .{ .require_deterministic = true };
    const cases = [_]Rejection{
        .{ .bytes = &.{ 0x18, 0x17 }, .err = error.NonPreferredArgument, .offset = 0 },
        .{ .bytes = &.{ 0x19, 0x00, 0xff }, .err = error.NonPreferredArgument, .offset = 0 },
        .{ .bytes = &.{ 0x1a, 0x00, 0x00, 0xff, 0xff }, .err = error.NonPreferredArgument, .offset = 0 },
        .{ .bytes = &.{ 0x1b, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff }, .err = error.NonPreferredArgument, .offset = 0 },
        .{ .bytes = &.{ 0x58, 0x01, 0x00 }, .err = error.NonPreferredArgument, .offset = 0 },
        .{ .bytes = &.{ 0x81, 0x38, 0x00 }, .err = error.NonPreferredArgument, .offset = 1 },
        .{ .bytes = &.{ 0xd8, 0x01, 0x00 }, .err = error.NonPreferredArgument, .offset = 0 },
        .{ .bytes = &.{ 0x5f, 0xff }, .err = error.IndefiniteLengthNotAllowed, .offset = 0 },
        .{ .bytes = &.{ 0x7f, 0xff }, .err = error.IndefiniteLengthNotAllowed, .offset = 0 },
        .{ .bytes = &.{ 0x9f, 0xff }, .err = error.IndefiniteLengthNotAllowed, .offset = 0 },
        .{ .bytes = &.{ 0xbf, 0xff }, .err = error.IndefiniteLengthNotAllowed, .offset = 0 },
        .{ .bytes = &.{ 0xfa, 0x3f, 0x80, 0x00, 0x00 }, .err = error.NonPreferredFloat, .offset = 0 },
        .{ .bytes = &.{ 0xfb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 }, .err = error.NonPreferredFloat, .offset = 0 },
        .{ .bytes = &.{ 0xfb, 0x40, 0xf8, 0x6a, 0, 0, 0, 0, 0 }, .err = error.NonPreferredFloat, .offset = 0 },
        .{ .bytes = &.{ 0xfb, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0 }, .err = error.NonPreferredFloat, .offset = 0 },
        .{ .bytes = &.{ 0xa2, 0x02, 0x00, 0x01, 0x00 }, .err = error.UnsortedMapKeys, .offset = 3 },
        .{ .bytes = &.{ 0xa2, 0x61, 'b', 0x00, 0x61, 'a', 0x00 }, .err = error.UnsortedMapKeys, .offset = 4 },
        .{ .bytes = &.{ 0xa2, 0x61, 'a', 0x00, 0x02, 0x00 }, .err = error.UnsortedMapKeys, .offset = 4 },
    };
    for (cases) |c| try validate(std.testing.allocator, c.bytes, .{});
    try Rejection.expectAll(&cases, deterministic);

    try Rejection.expectAll(&.{
        .{ .bytes = &.{ 0xa2, 0x01, 0x00, 0x01, 0x00 }, .err = error.DuplicateMapKey, .offset = 3 },
        .{ .bytes = &.{ 0xa2, 0xf9, 0x00, 0x00, 0x00, 0xf9, 0x80, 0x00, 0x00 }, .err = error.DuplicateMapKey, .offset = 0 },
    }, deterministic);

    const accepted = [_][]const u8{
        &.{ 0xa3, 0x01, 0x00, 0x20, 0x00, 0x61, 'a', 0x00 },
        &.{ 0xf9, 0x3c, 0x00 },
        &.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 },
        &.{ 0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a },
        &.{ 0xf8, 0xff },
        &.{ 0xc1, 0x1a, 0x51, 0x4b, 0x67, 0xb0 },
    };
    for (accepted) |input| try validate(std.testing.allocator, input, deterministic);

    const gpa = std.testing.allocator;
    try Rejection.expectAll(&.{
        .{ .bytes = &.{ 0x81, 0x81, 0x81, 0x00 }, .err = error.DepthLimitExceeded, .offset = 2 },
        .{ .bytes = &.{ 0xc1, 0xc1, 0xc1, 0x00 }, .err = error.DepthLimitExceeded, .offset = 2 },
    }, .{ .limits = .{ .max_depth = 2 } });
    try validate(gpa, &.{ 0x81, 0x81, 0x81, 0x00 }, .{ .limits = .{ .max_depth = 3 } });

    try Rejection.expectAll(&.{
        .{ .bytes = &.{ 0x83, 0x01, 0x02, 0x03 }, .err = error.ItemLimitExceeded, .offset = 0 },
        .{ .bytes = &.{ 0x9f, 0x01, 0x02, 0x03, 0xff }, .err = error.ItemLimitExceeded, .offset = 3 },
    }, .{ .limits = .{ .max_items = 3 } });
    try validate(gpa, &.{ 0x83, 0x01, 0x02, 0x03 }, .{ .limits = .{ .max_items = 4 } });

    try Rejection.expectAll(&.{
        .{ .bytes = &.{ 0x43, 0x01, 0x02, 0x03 }, .err = error.StringLengthLimitExceeded, .offset = 0 },
        .{ .bytes = &.{ 0x5f, 0x42, 0x01, 0x02, 0x41, 0x03, 0xff }, .err = error.StringLengthLimitExceeded, .offset = 4 },
    }, .{ .limits = .{ .max_string_bytes = 2 } });

    const small_budget: DecodeOptions = .{ .limits = .{ .max_allocation_bytes = 2 } };
    try std.testing.expectError(error.AllocationLimitExceeded, decodeValue(gpa, &.{ 0x43, 0x01, 0x02, 0x03 }, small_budget));
    try validate(gpa, &.{ 0x43, 0x01, 0x02, 0x03 }, small_budget);

    try std.testing.expectError(error.WorkLimitExceeded, validate(gpa, &.{ 0x82, 0x01, 0x02 }, .{ .limits = .{ .max_work = 2 } }));
    try validate(gpa, &.{ 0x82, 0x01, 0x02 }, .{ .limits = .{ .max_work = 3 } });
}

test "allocation budget is cumulative across frees and shrinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = Decoder.init(arena.allocator(), &.{}, .{ .limits = .{ .max_allocation_bytes = 8 } });
    const budgeted = d.allocator();

    const block = try budgeted.alloc(u8, 4);
    const kept: usize = if (budgeted.resize(block, 1)) 1 else block.len;
    budgeted.free(block[0..kept]);
    try std.testing.expectEqual(@as(usize, 4), d.allocated);

    budgeted.free(try budgeted.alloc(u8, 4));
    try std.testing.expectEqual(@as(usize, 8), d.allocated);
    try std.testing.expectError(error.OutOfMemory, budgeted.alloc(u8, 1));
    try std.testing.expect(d.allocationFailure() == error.AllocationLimitExceeded);
    try std.testing.expectEqual(@as(usize, 8), d.allocated);
}

test "allocation budget spans every map in one decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nine = [_]u8{ 0xa9, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00, 0x09, 0x00 };
    var probe = Decoder.init(arena.allocator(), &nine, .{});
    try probe.skip();
    try probe.finish();
    try std.testing.expect(probe.allocated > 0);

    const one_map: DecodeOptions = .{ .limits = .{ .max_allocation_bytes = probe.allocated } };
    try validate(arena.allocator(), &nine, one_map);
    try std.testing.expectError(error.AllocationLimitExceeded, validate(arena.allocator(), &([_]u8{0x82} ++ nine ++ nine), one_map));
}

test "distinct keys of different types are not duplicates" {
    const inputs = [_][]const u8{
        &.{ 0xa2, 0x01, 0x00, 0xf9, 0x3c, 0x00, 0x00 },
        &.{ 0xa2, 0x41, 'a', 0x00, 0x61, 'a', 0x00 },
        &.{ 0xa2, 0x02, 0x00, 0xc2, 0x41, 0x02, 0x00 },
        &.{ 0xa2, 0xf4, 0x00, 0x00, 0x00 },
        &.{ 0xa2, 0xf9, 0x7e, 0x00, 0x00, 0xf9, 0x7e, 0x01, 0x00 },
    };
    for (inputs) |input| try validate(std.testing.allocator, input, .{});
}

test "small maps track keys without allocating" {
    try validate(std.testing.failing_allocator, &.{ 0xa2, 0x01, 0x00, 0x02, 0x00 }, .{});
    const nine = [_]u8{ 0xa9, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00, 0x09, 0x00 };
    try std.testing.expectError(error.OutOfMemory, validate(std.testing.failing_allocator, &nine, .{}));
    try validate(std.testing.allocator, &nine, .{});
}

test "map pull API matches keys and re-reads typed keys" {
    const gpa = std.testing.allocator;
    var d = Decoder.init(gpa, "\xa3\x64name\x61x\x01\x02\x7f\x61i\x61d\xff\x18\x07", .{});
    var m = try d.beginMap();
    defer m.deinit(&d);
    var name: ?StringRef = null;
    var one: ?u64 = null;
    var id: ?u64 = null;
    while (try d.nextMapKey(&m)) |key| {
        if (key.isText("name")) {
            name = try d.readTextRef();
        } else if (key.isInt(1)) {
            one = try d.readUint();
        } else if (key.isText("id")) {
            d.rereadKey(key);
            const text = try d.readTextRef();
            defer text.deinit(d.allocator());
            try std.testing.expect(text.owned);
            try std.testing.expectEqualStrings("id", text.bytes);
            id = try d.readUint();
        } else {
            return error.UnexpectedMapKey;
        }
    }
    try d.endMap(&m);
    try d.finish();
    try std.testing.expectEqualStrings("x", name.?.bytes);
    try std.testing.expectEqual(@as(?u64, 2), one);
    try std.testing.expectEqual(@as(?u64, 7), id);
    try std.testing.expectEqual(@as(u64, 7), d.items);
}

test "array pull API reports length mismatches" {
    var d = Decoder.init(std.testing.allocator, &.{ 0x83, 0x01, 0x02, 0x03 }, .{});
    var a = try d.beginArray();
    try std.testing.expectEqual(@as(?u64, 3), a.count);
    _ = try d.nextArrayItem(&a);
    _ = try d.readUint();
    try std.testing.expectError(error.LengthMismatch, d.endArray(&a));

    d = Decoder.init(std.testing.allocator, &.{ 0x9f, 0x01, 0x02, 0xff }, .{});
    a = try d.beginArray();
    var sum: u64 = 0;
    while (!try d.arrayAtEnd(&a)) {
        try std.testing.expect(try d.nextArrayItem(&a));
        sum += try d.readUint();
    }
    try d.endArray(&a);
    try d.finish();
    try std.testing.expectEqual(@as(u64, 3), sum);
}

test "checkpoints support backtracking" {
    var d = Decoder.init(std.testing.allocator, &.{ 0x82, 0x61, 'a', 0x01 }, .{});
    const cp = d.save();
    var a = try d.beginArray();
    try std.testing.expect(try d.nextArrayItem(&a));
    try std.testing.expectError(error.TypeMismatch, d.readInt());
    try std.testing.expectEqual(Kind.text, try d.peekKind());
    d.restore(cp);
    try std.testing.expectEqual(@as(u32, 0), d.depth);
    try std.testing.expectEqual(@as(u64, 0), d.items);
    try d.skip();
    try d.finish();
}

test "decoding releases every allocation on failure" {
    const Roundtrip = struct {
        fn decodeAndFree(gpa: Allocator, bytes: []const u8) !void {
            const value = try decodeValue(gpa, bytes, .{});
            value.deinit(gpa);
        }
    };

    const input = [_]u8{
        0xbf,
        0x61,
        'a',
        0x9f,
        0x01,
        0x5f,
        0x41,
        0x02,
        0xff,
        0xc1,
        0x02,
        0xff,
        0xa1,
        0x7f,
        0x61,
        'k',
        0xff,
        0x82,
        0xf9,
        0x3c,
        0x00,
        0x63,
        'x',
        'y',
        'z',
        0xf6,
        0x7f,
        0x61,
        'b',
        0xff,
        0x80,
        0xff,
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Roundtrip.decodeAndFree, .{@as([]const u8, &input)});
}
