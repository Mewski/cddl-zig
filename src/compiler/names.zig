const std = @import("std");

pub const Style = enum { pascal_case, snake_case };

/// Source-ordered identifier allocation. Returned names belong to the caller's allocator.
pub const Names = struct {
    allocator: std.mem.Allocator,
    style: Style = .snake_case,
    used: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Names) void {
        self.used.deinit(self.allocator);
    }

    pub fn reserve(self: *Names, name: []const u8) !void {
        try self.used.put(self.allocator, name, {});
    }

    pub fn allocate(self: *Names, source: []const u8) ![]const u8 {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);
        var boundary = true;
        for (source, 0..) |byte, index| {
            if (!std.ascii.isAlphanumeric(byte)) {
                boundary = true;
                continue;
            }
            const camel_boundary = index != 0 and std.ascii.isUpper(byte) and
                (std.ascii.isLower(source[index - 1]) or std.ascii.isDigit(source[index - 1]) or
                    (std.ascii.isUpper(source[index - 1]) and index + 1 < source.len and std.ascii.isLower(source[index + 1])));
            const word_start = boundary or camel_boundary;
            if (word_start and buffer.items.len != 0 and self.style == .snake_case) try buffer.append(self.allocator, '_');
            try buffer.append(self.allocator, if (word_start and self.style == .pascal_case) std.ascii.toUpper(byte) else std.ascii.toLower(byte));
            boundary = false;
        }
        const prefix = if (self.style == .pascal_case) "Schema" else "schema_";
        if (buffer.items.len == 0) {
            try buffer.appendSlice(self.allocator, if (self.style == .pascal_case) "Schema" else "schema");
        } else if (std.ascii.isDigit(buffer.items[0]) or std.zig.Token.getKeyword(buffer.items) != null or std.zig.isPrimitive(buffer.items) or std.mem.startsWith(u8, buffer.items, "__cddl")) {
            try buffer.insertSlice(self.allocator, 0, prefix);
        }
        const base = try self.allocator.dupe(u8, buffer.items);
        errdefer self.allocator.free(base);
        var result = base;
        errdefer if (result.ptr != base.ptr) self.allocator.free(result);
        var suffix: usize = 2;
        while (self.used.contains(result)) {
            const next = try std.fmt.allocPrint(self.allocator, "{s}{s}{d}", .{ base, if (self.style == .pascal_case) "" else "_", suffix });
            if (result.ptr != base.ptr) self.allocator.free(result);
            result = next;
            suffix = try std.math.add(usize, suffix, 1);
        }
        try self.reserve(result);
        if (result.ptr != base.ptr) self.allocator.free(base);
        return result;
    }
};

test "snake case names normalize word boundaries and protect keywords" {
    const allocator = std.testing.allocator;
    var names = Names{ .allocator = allocator };
    defer names.deinit();
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "my-packet", .expected = "my_packet" },
        .{ .source = "myPacket", .expected = "my_packet_2" },
        .{ .source = "HTTPServer", .expected = "http_server" },
        .{ .source = "struct", .expected = "schema_struct" },
        .{ .source = "u64", .expected = "schema_u64" },
        .{ .source = "123-field", .expected = "schema_123_field" },
        .{ .source = "__cddl_value", .expected = "cddl_value" },
        .{ .source = "", .expected = "schema" },
    };
    var allocated: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated.items) |name| allocator.free(name);
        allocated.deinit(allocator);
    }
    for (cases) |case| {
        const name = try names.allocate(case.source);
        allocated.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
        try std.testing.expectEqualStrings(case.expected, name);
    }
}

test "PascalCase names preserve type conventions through deterministic collisions" {
    const allocator = std.testing.allocator;
    var names = Names{ .allocator = allocator, .style = .pascal_case };
    defer names.deinit();
    try names.reserve("Value");
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "packet", .expected = "Packet" },
        .{ .source = "packetCodec", .expected = "PacketCodec" },
        .{ .source = "my-packet", .expected = "MyPacket" },
        .{ .source = "my.packet", .expected = "MyPacket2" },
        .{ .source = "MyPacket2", .expected = "MyPacket22" },
        .{ .source = "packet-codec", .expected = "PacketCodec2" },
        .{ .source = "struct", .expected = "Struct" },
        .{ .source = "u64", .expected = "U64" },
        .{ .source = "123-packet", .expected = "Schema123Packet" },
        .{ .source = "value", .expected = "Value2" },
        .{ .source = "__cddl_Type", .expected = "CddlType" },
    };
    var allocated: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated.items) |name| allocator.free(name);
        allocated.deinit(allocator);
    }
    for (cases) |case| {
        const name = try names.allocate(case.source);
        allocated.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
        try std.testing.expectEqualStrings(case.expected, name);
    }
}
