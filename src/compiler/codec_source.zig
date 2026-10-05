const __cddl_Number = union(enum) { integer: i65, float: f64 };
const __cddl_Literal = union(enum) { integer: i65, float: f64, text: []const u8, bytes: []const u8 };
const __cddl_Field = struct { name: []const u8, value: usize, key: ?usize, min: u64, max: ?u64 };
const __cddl_Head = struct { major: ?u3, number: ?u64, number_type: ?usize, content: ?usize };
const __cddl_Operator = enum { size, bits, cbor, within, @"and", lt, le, gt, ge, eq, ne, default };
const __cddl_Node = union(enum) {
    never,
    alias: usize,
    literal: __cddl_Literal,
    range: struct { lower: __cddl_Number, upper: __cddl_Number, inclusive: bool },
    control: struct { operator: __cddl_Operator, target: usize, controller: usize, size_max: ?u64 },
    choice: []const usize,
    array: []const __cddl_Field,
    map: []const __cddl_Field,
    head: __cddl_Head,
};
const __cddl_Error = __cddl_rt.Error;
const __cddl_Scalar = enum { integer, float, boolean };

fn __cddl_scalar(comptime id: usize) ?__cddl_Scalar {
    return switch (__cddl_nodes[id]) {
        .alias => |child| __cddl_scalar(child),
        .head => |head| if (head.major == 0 or head.major == 1)
            (if (head.number == null) .integer else null)
        else if (head.major == 7 and head.number != null)
            switch (head.number.?) {
                20, 21 => .boolean,
                25...27 => .float,
                else => null,
            }
        else
            null,
        .choice => |children| result: {
            if (children.len == 0) break :result null;
            const first = __cddl_scalar(children[0]) orelse break :result null;
            for (children[1..]) |child| if (__cddl_scalar(child) != first) break :result null;
            break :result first;
        },
        else => null,
    };
}

fn __cddl_Codec(comptime id: usize) type {
    return struct {
        pub const Value = __cddl_Type(id);
        pub const Decoded = struct {
            arena: __cddl_std.heap.ArenaAllocator,
            value: Value,

            pub fn deinit(self: *Decoded) void {
                self.arena.deinit();
                self.* = undefined;
            }
        };

        pub fn validate(allocator: __cddl_std.mem.Allocator, value: Value) __cddl_Error!void {
            var arena = __cddl_std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const raw = try __cddl_to(id, arena.allocator(), value);
            try __cddl_valid(raw, 0);
            if (!try __cddl_matches(arena.allocator(), id, raw, 0)) return error.ConstraintViolation;
        }

        /// Returned bytes belong to allocator. Encoding is core deterministic CBOR.
        pub fn encode(allocator: __cddl_std.mem.Allocator, value: Value) __cddl_Error![]u8 {
            var arena = __cddl_std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const raw = try __cddl_to(id, arena.allocator(), value);
            try __cddl_valid(raw, 0);
            if (!try __cddl_matches(arena.allocator(), id, raw, 0)) return error.ConstraintViolation;
            return __cddl_rt.encodeValueAlloc(allocator, raw);
        }

        /// Decoded owns all nested storage, independently of the input bytes.
        pub fn decode(allocator: __cddl_std.mem.Allocator, input: []const u8, options: __cddl_rt.DecodeOptions) __cddl_Error!Decoded {
            var arena = __cddl_std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const raw = try __cddl_rt.decodeValue(arena.allocator(), input, options);
            if (!try __cddl_matches(arena.allocator(), id, raw, 0)) return error.ConstraintViolation;
            const value = try __cddl_from(id, arena.allocator(), raw);
            return .{ .arena = arena, .value = value };
        }
    };
}

fn __cddl_valid(value: __cddl_rt.Value, depth: u32) __cddl_Error!void {
    if (depth >= 256) return error.DepthLimitExceeded;
    switch (value) {
        .text => |text| if (!__cddl_std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8,
        .simple => |number| if (number >= 24 and number < 32) return error.InvalidSimpleValue,
        .array => |items| for (items) |item| try __cddl_valid(item, depth + 1),
        .map => |entries| {
            for (entries, 0..) |entry, index| {
                try __cddl_valid(entry.key, depth + 1);
                try __cddl_valid(entry.value, depth + 1);
                for (entries[0..index]) |previous| if (entry.key.eql(previous.key)) return error.DuplicateMapKey;
            }
        },
        .tag => |tag| try __cddl_valid(tag.content.*, depth + 1),
        else => {},
    }
}

fn __cddl_literal(value: __cddl_Literal) __cddl_rt.Value {
    return switch (value) {
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .text => |v| .{ .text = v },
        .bytes => |v| .{ .bytes = v },
    };
}

fn __cddl_literal_equal(value: __cddl_rt.Value, literal: __cddl_Literal) bool {
    return switch (literal) {
        .integer => |expected| value == .integer and value.integer == expected,
        .float => |expected| value == .float and @as(u64, @bitCast(value.float)) == @as(u64, @bitCast(expected)),
        .text => |expected| value == .text and __cddl_std.mem.eql(u8, value.text, expected),
        .bytes => |expected| value == .bytes and __cddl_std.mem.eql(u8, value.bytes, expected),
    };
}

fn __cddl_constant(id: usize) __cddl_rt.Value {
    return switch (__cddl_nodes[id]) {
        .literal => |value| __cddl_literal(value),
        .alias => |child| __cddl_constant(child),
        .choice => |children| __cddl_constant(children[0]),
        .range => |range| switch (range.lower) {
            .integer => |number| .{ .integer = number },
            .float => |number| .{ .float = number },
        },
        .head => |head| switch (head.major.?) {
            0 => .{ .integer = head.number.? },
            1 => .{ .integer = -1 - @as(i65, head.number.?) },
            7 => switch (head.number.?) {
                20 => .{ .boolean = false },
                21 => .{ .boolean = true },
                22 => .null,
                23 => .undefined,
                else => .{ .simple = @intCast(head.number.?) },
            },
            else => unreachable,
        },
        else => unreachable,
    };
}

fn __cddl_numeric(value: __cddl_rt.Value) ?f128 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| @floatCast(v),
        else => null,
    };
}

fn __cddl_bound(value: __cddl_Number) f128 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| @floatCast(v),
    };
}

fn __cddl_equal(a: __cddl_rt.Value, b: __cddl_rt.Value) bool {
    if (__cddl_numeric(a)) |x| {
        if (__cddl_numeric(b)) |y| return x == y;
    }
    return a.eql(b);
}

fn __cddl_simple(value: __cddl_rt.Value) ?u8 {
    return switch (value) {
        .simple => |number| number,
        .boolean => |b| if (b) 21 else 20,
        .null => 22,
        .undefined => 23,
        else => null,
    };
}

fn __cddl_argument(number: ?u64, value: u64) bool {
    const n = number orelse return true;
    return switch (n) {
        0...23 => value == n,
        24 => value <= 0xff,
        25 => value <= 0xffff,
        26 => value <= 0xffffffff,
        27, 31 => true,
        else => false,
    };
}

fn __cddl_head(allocator: __cddl_std.mem.Allocator, head: __cddl_Head, value: __cddl_rt.Value, depth: u32) __cddl_Error!bool {
    const major = head.major orelse return true;
    switch (major) {
        0 => return value == .integer and value.integer >= 0 and __cddl_argument(head.number, @intCast(value.integer)),
        1 => return value == .integer and value.integer < 0 and __cddl_argument(head.number, @intCast(-1 - value.integer)),
        2 => return value == .bytes and __cddl_argument(head.number, @intCast(value.bytes.len)),
        3 => return value == .text and __cddl_argument(head.number, @intCast(value.text.len)),
        4 => return value == .array and __cddl_argument(head.number, @intCast(value.array.len)),
        5 => return value == .map and __cddl_argument(head.number, @intCast(value.map.len)),
        6 => {
            if (value != .tag) return false;
            if (head.number) |number| if (value.tag.number != number) return false;
            if (head.number_type) |child| if (!try __cddl_matches(allocator, child, .{ .integer = value.tag.number }, depth + 1)) return false;
            if (head.content) |child| return __cddl_matches(allocator, child, value.tag.content.*, depth + 1);
            return true;
        },
        7 => {
            const number = head.number orelse return value == .float or __cddl_simple(value) != null;
            if (number >= 25 and number <= 27) {
                if (value != .float) return false;
                if (__cddl_std.math.isNan(value.float) or number == 27) return true;
                if (number == 25) return @as(f64, @as(f16, @floatCast(value.float))) == value.float;
                return @as(f64, @as(f32, @floatCast(value.float))) == value.float;
            }
            return if (__cddl_simple(value)) |simple| @as(u64, simple) == number else false;
        },
    }
}

fn __cddl_matches(allocator: __cddl_std.mem.Allocator, id: usize, value: __cddl_rt.Value, depth: u32) __cddl_Error!bool {
    if (depth >= 256) return error.DepthLimitExceeded;
    switch (__cddl_nodes[id]) {
        .never => return false,
        .alias => |child| return __cddl_matches(allocator, child, value, depth + 1),
        .literal => |literal| return __cddl_literal_equal(value, literal),
        .head => |head| return __cddl_head(allocator, head, value, depth),
        .range => |range| {
            if (range.lower == .integer and range.upper == .integer) {
                if (value != .integer) return false;
            } else if (value != .float) return false;
            const number = __cddl_numeric(value) orelse return false;
            return number >= __cddl_bound(range.lower) and (if (range.inclusive) number <= __cddl_bound(range.upper) else number < __cddl_bound(range.upper));
        },
        .choice => |children| {
            for (children) |child| if (try __cddl_matches(allocator, child, value, depth + 1)) return true;
            return false;
        },
        .array => |fields| {
            if (value != .array) return false;
            var position: usize = 0;
            for (fields) |field| {
                var count: u64 = 0;
                while (position < value.array.len and (field.max == null or count < field.max.?)) {
                    if (!try __cddl_matches(allocator, field.value, value.array[position], depth + 1)) break;
                    position += 1;
                    count += 1;
                }
                if (count < field.min) return false;
            }
            return position == value.array.len;
        },
        .map => |fields| {
            if (value != .map) return false;
            for (value.map, 0..) |entry, index| {
                for (value.map[0..index]) |previous| if (entry.key.eql(previous.key)) return error.DuplicateMapKey;
                var found = false;
                for (fields) |field| {
                    if (!entry.key.eql(__cddl_constant(field.key.?))) continue;
                    if (field.max == 0 or !try __cddl_matches(allocator, field.value, entry.value, depth + 1)) return false;
                    found = true;
                    break;
                }
                if (!found) return false;
            }
            for (fields) |field| {
                if (field.min == 0) continue;
                var found = false;
                for (value.map) |entry| if (entry.key.eql(__cddl_constant(field.key.?))) {
                    found = true;
                    break;
                };
                if (!found) return false;
            }
            return true;
        },
        .control => |control| {
            if (!try __cddl_matches(allocator, control.target, value, depth + 1)) return false;
            switch (control.operator) {
                .default => return true,
                .@"and", .within => return __cddl_matches(allocator, control.controller, value, depth + 1),
                .eq, .ne => {
                    const equal = __cddl_equal(value, __cddl_constant(control.controller));
                    return if (control.operator == .eq) equal else !equal;
                },
                .lt, .le, .gt, .ge => {
                    const left = __cddl_numeric(value) orelse return false;
                    const right = __cddl_numeric(__cddl_constant(control.controller)) orelse return false;
                    return switch (control.operator) {
                        .lt => left < right,
                        .le => left <= right,
                        .gt => left > right,
                        .ge => left >= right,
                        else => unreachable,
                    };
                },
                .size => {
                    const size = control.size_max orelse return false;
                    return switch (value) {
                        .text => |bytes| __cddl_matches(allocator, control.controller, .{ .integer = @intCast(bytes.len) }, depth + 1),
                        .bytes => |bytes| __cddl_matches(allocator, control.controller, .{ .integer = @intCast(bytes.len) }, depth + 1),
                        .integer => |integer| integer >= 0 and (size >= 8 or @as(u64, @intCast(integer)) < (@as(u64, 1) << @as(u6, @intCast(size * 8)))),
                        else => false,
                    };
                },
                .bits => switch (value) {
                    .integer => |integer| {
                        if (integer < 0) return false;
                        const bits: u64 = @intCast(integer);
                        for (0..64) |bit| if (bits & (@as(u64, 1) << @as(u6, @intCast(bit))) != 0) {
                            if (!try __cddl_matches(allocator, control.controller, .{ .integer = @intCast(bit) }, depth + 1)) return false;
                        };
                        return true;
                    },
                    .bytes => |bytes| {
                        for (bytes, 0..) |byte, index| {
                            for (0..8) |bit| if (byte & (@as(u8, 1) << @as(u3, @intCast(bit))) != 0) {
                                const offset = __cddl_std.math.mul(u64, @intCast(index), 8) catch return error.WorkLimitExceeded;
                                const position = __cddl_std.math.add(u64, offset, @intCast(bit)) catch return error.WorkLimitExceeded;
                                if (!try __cddl_matches(allocator, control.controller, .{ .integer = position }, depth + 1)) return false;
                            };
                        }
                        return true;
                    },
                    else => return false,
                },
                .cbor => {
                    if (value != .bytes) return false;
                    const embedded = __cddl_rt.decodeValue(allocator, value.bytes, .{}) catch |err| switch (err) {
                        error.OutOfMemory, error.DepthLimitExceeded, error.ItemLimitExceeded, error.StringLengthLimitExceeded, error.AllocationLimitExceeded, error.WorkLimitExceeded => return err,
                        else => return false,
                    };
                    defer embedded.deinit(allocator);
                    return __cddl_matches(allocator, control.controller, embedded, depth + 1);
                },
            }
        },
    }
}

fn __cddl_to(comptime id: usize, allocator: __cddl_std.mem.Allocator, value: __cddl_Type(id)) __cddl_Error!__cddl_rt.Value {
    switch (comptime __cddl_nodes[id]) {
        .never => unreachable,
        .alias => |child| return __cddl_to(child, allocator, value),
        .control => |control| return __cddl_to(control.target, allocator, value),
        .literal => |literal| return switch (comptime literal) {
            .integer => .{ .integer = value },
            .float => .{ .float = value },
            .text => .{ .text = value },
            .bytes => .{ .bytes = value },
        },
        .range => |range| return if (comptime range.lower == .integer and range.upper == .integer) .{ .integer = value } else .{ .float = value },
        .choice => |children| {
            if (comptime children.len == 0) unreachable;
            if (comptime children.len == 1) return __cddl_to(children[0], allocator, value);
            if (comptime __cddl_scalar(id)) |kind| return switch (comptime kind) {
                .integer => .{ .integer = value },
                .float => .{ .float = value },
                .boolean => .{ .boolean = value },
            };
            inline for (children, 0..) |child, index| {
                const name = __cddl_std.fmt.comptimePrint("choice_{d}", .{index});
                if (value == @field(__cddl_std.meta.Tag(__cddl_Type(id)), name)) {
                    const raw = try __cddl_to(child, allocator, @field(value, name));
                    if (!try __cddl_matches(allocator, child, raw, 0)) return error.ConstraintViolation;
                    return raw;
                }
            }
            unreachable;
        },
        .array, .map => |fields| {
            const is_map = comptime __cddl_nodes[id] == .map;
            const Item = if (is_map) __cddl_rt.Value.Entry else __cddl_rt.Value;
            var count: usize = 0;
            inline for (fields) |field| {
                const child = @field(value, field.name);
                const n: usize = if (comptime field.min == 1 and field.max == 1) 1 else if (comptime field.max == 1) @intFromBool(child != null) else child.len;
                if (n < field.min or (field.max != null and n > field.max.?)) return error.ConstraintViolation;
                count = __cddl_std.math.add(usize, count, n) catch return error.AllocationLimitExceeded;
            }
            const items = try allocator.alloc(Item, count);
            var position: usize = 0;
            inline for (fields) |field| {
                const child = @field(value, field.name);
                if (comptime field.min == 1 and field.max == 1) {
                    const raw = try __cddl_to(field.value, allocator, child);
                    if (!try __cddl_matches(allocator, field.value, raw, 0)) return error.ConstraintViolation;
                    items[position] = if (is_map) .{ .key = __cddl_constant(field.key.?), .value = raw } else raw;
                    position += 1;
                } else if (comptime field.max == 1) {
                    if (child) |present| {
                        const raw = try __cddl_to(field.value, allocator, present);
                        if (!try __cddl_matches(allocator, field.value, raw, 0)) return error.ConstraintViolation;
                        items[position] = if (is_map) .{ .key = __cddl_constant(field.key.?), .value = raw } else raw;
                        position += 1;
                    }
                } else {
                    for (child) |present| {
                        const raw = try __cddl_to(field.value, allocator, present);
                        if (!try __cddl_matches(allocator, field.value, raw, 0)) return error.ConstraintViolation;
                        items[position] = if (is_map) .{ .key = __cddl_constant(field.key.?), .value = raw } else raw;
                        position += 1;
                    }
                }
            }
            return if (is_map) .{ .map = items } else .{ .array = items };
        },
        .head => |head| switch (comptime if (head.major) |major| @as(u4, major) else 8) {
            0, 1 => return .{ .integer = value },
            2 => return .{ .bytes = value },
            3 => return .{ .text = value },
            4 => return .{ .array = @constCast(value) },
            5 => return .{ .map = @constCast(value) },
            6 => {
                const content = try allocator.create(__cddl_rt.Value);
                content.* = if (comptime head.content) |child| try __cddl_to(child, allocator, value.content) else value.content;
                return .{ .tag = .{ .number = value.number, .content = content } };
            },
            7 => {
                if (comptime head.number) |number| return switch (comptime number) {
                    20, 21 => .{ .boolean = value },
                    22 => .null,
                    23 => .undefined,
                    25...27 => .{ .float = value },
                    else => .{ .simple = value },
                };
                return value.value;
            },
            else => return value.value,
        },
    }
}

fn __cddl_from(comptime id: usize, allocator: __cddl_std.mem.Allocator, value: __cddl_rt.Value) __cddl_Error!__cddl_Type(id) {
    switch (comptime __cddl_nodes[id]) {
        .never => return error.NoMatchingChoice,
        .alias => |child| return __cddl_from(child, allocator, value),
        .control => |control| return __cddl_from(control.target, allocator, value),
        .literal => |literal| return switch (comptime literal) {
            .integer => value.integer,
            .float => value.float,
            .text => value.text,
            .bytes => value.bytes,
        },
        .range => |range| return if (comptime range.lower == .integer and range.upper == .integer) value.integer else value.float,
        .choice => |children| {
            if (comptime children.len == 0) return error.NoMatchingChoice;
            if (comptime children.len == 1) return __cddl_from(children[0], allocator, value);
            if (comptime __cddl_scalar(id)) |kind| return switch (comptime kind) {
                .integer => value.integer,
                .float => value.float,
                .boolean => value.boolean,
            };
            inline for (children, 0..) |child, index| {
                if (try __cddl_matches(allocator, child, value, 0)) return @unionInit(__cddl_Type(id), __cddl_std.fmt.comptimePrint("choice_{d}", .{index}), try __cddl_from(child, allocator, value));
            }
            return error.NoMatchingChoice;
        },
        .array => |fields| {
            var result: __cddl_Type(id) = undefined;
            var position: usize = 0;
            inline for (fields) |field| {
                const start = position;
                var count: u64 = 0;
                while (position < value.array.len and (field.max == null or count < field.max.?)) {
                    if (!try __cddl_matches(allocator, field.value, value.array[position], 0)) break;
                    count += 1;
                    position += 1;
                }
                if (comptime field.min == 1 and field.max == 1) {
                    @field(result, field.name) = try __cddl_from(field.value, allocator, value.array[start]);
                } else if (comptime field.max == 1) {
                    @field(result, field.name) = if (count == 0) null else try __cddl_from(field.value, allocator, value.array[start]);
                } else {
                    const items = try allocator.alloc(__cddl_Type(field.value), @intCast(count));
                    for (items, value.array[start..position]) |*item, raw| item.* = try __cddl_from(field.value, allocator, raw);
                    @field(result, field.name) = items;
                }
            }
            return result;
        },
        .map => |fields| {
            var result: __cddl_Type(id) = undefined;
            inline for (fields) |field| {
                if (comptime field.max == 0) {
                    @field(result, field.name) = &.{};
                } else {
                    if (comptime field.min == 0) @field(result, field.name) = null;
                    for (value.map) |entry| {
                        if (!entry.key.eql(__cddl_constant(field.key.?))) continue;
                        @field(result, field.name) = try __cddl_from(field.value, allocator, entry.value);
                        break;
                    }
                }
            }
            return result;
        },
        .head => |head| switch (comptime if (head.major) |major| @as(u4, major) else 8) {
            0 => return @intCast(value.integer),
            1 => return value.integer,
            2 => return value.bytes,
            3 => return value.text,
            4 => return value.array,
            5 => return value.map,
            6 => return .{ .number = value.tag.number, .content = if (comptime head.content) |child| try __cddl_from(child, allocator, value.tag.content.*) else value.tag.content.* },
            7 => {
                if (comptime head.number) |number| return switch (comptime number) {
                    20, 21 => value.boolean,
                    22, 23 => {},
                    25...27 => value.float,
                    else => value.simple,
                };
                return .{ .value = value };
            },
            else => return .{ .value = value },
        },
    }
}
