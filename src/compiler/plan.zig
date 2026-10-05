const std = @import("std");
const model = @import("model.zig");
const names = @import("names.zig");

pub const Error = std.mem.Allocator.Error || error{
    Overflow,
    UnsupportedRecursion,
    UnsupportedGroupChoice,
    UnsupportedGroupOccurrence,
    UnsupportedMapKey,
    UnsupportedMapOccurrence,
    UnsupportedControl,
    UnsupportedHead,
    UnresolvedTemplate,
    InvalidModel,
};
pub const Field = struct {
    name: []const u8,
    value: model.NodeId,
    key: ?model.NodeId,
    occurrence: model.Occurrence,
};
pub const Export = struct {
    name: []const u8,
    codec_name: []const u8,
    node: model.NodeId,
};
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    source: *const model.Model,
    reachable: []bool,
    fields: []const []const Field,
    exports: []const Export,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Scalar = enum { integer, float, boolean };

/// Prelude scalar unions use their native scalar domain rather than redundant tags.
pub fn scalar(source: *const model.Model, id: model.NodeId) ?Scalar {
    return switch (source.node(id).data) {
        .reference => |child| scalar(source, child),
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
            const first = scalar(source, children[0]) orelse break :result null;
            for (children[1..]) |child| if (scalar(source, child) != first) break :result null;
            break :result first;
        },
        else => null,
    };
}

pub fn sizeMaximum(source: *const model.Model, id: model.NodeId) Error!?u64 {
    return sizeMaximumDepth(source, id, 0);
}

fn sizeMaximumDepth(source: *const model.Model, id: model.NodeId, depth: usize) Error!?u64 {
    if (depth > source.nodes.len) return error.UnsupportedRecursion;
    return switch (source.node(id).data) {
        .reference => |child| sizeMaximumDepth(source, child, depth + 1),
        .literal => |value| if (value == .integer and value.integer >= 0) @as(u64, @intCast(value.integer)) else error.UnsupportedControl,
        .range => |range| result: {
            if (range.lower != .integer or range.upper != .integer or range.lower.integer < 0 or range.upper.integer < 0) return error.UnsupportedControl;
            const upper: u64 = @intCast(range.upper.integer);
            if (!range.inclusive and upper == 0) break :result null;
            break :result if (range.inclusive) upper else upper - 1;
        },
        .head => |head| if (head.major == 0 and head.number_type == null)
            (if (head.number) |number| switch (number) {
                0...23 => number,
                24 => 0xff,
                25 => 0xffff,
                26 => 0xffffffff,
                27 => std.math.maxInt(u64),
                else => return error.UnsupportedControl,
            } else std.math.maxInt(u64))
        else
            error.UnsupportedControl,
        .choice => |children| result: {
            var maximum: ?u64 = null;
            for (children) |child| {
                const current = (try sizeMaximumDepth(source, child, depth + 1)) orelse continue;
                maximum = if (maximum) |previous| @max(previous, current) else current;
            }
            break :result maximum;
        },
        else => error.UnsupportedControl,
    };
}

/// The failing normalized node, when requested, is set before returning an error.
pub fn build(allocator: std.mem.Allocator, source: *const model.Model, failed_node: ?*?model.NodeId) Error!Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var builder = Builder{
        .allocator = a,
        .source = source,
        .colors = try a.alloc(u2, source.nodes.len),
        .reachable = try a.alloc(bool, source.nodes.len),
        .fields = try a.alloc([]const Field, source.nodes.len),
        .failed_node = failed_node,
    };
    @memset(builder.colors, 0);
    @memset(builder.reachable, false);
    @memset(builder.fields, &.{});
    if (failed_node) |pointer| pointer.* = null;
    var identifiers = names.Names{ .allocator = a, .style = .pascal_case };
    defer identifiers.deinit();
    const support = @embedFile("codec_source.zig");
    var tokens = std.zig.Tokenizer.init(support);
    while (true) {
        const token = tokens.next();
        if (token.tag == .eof) break;
        if (token.tag == .identifier) try identifiers.reserve(support[token.loc.start..token.loc.end]);
    }
    var exports: std.ArrayList(Export) = .empty;
    for (source.rules, 0..) |rule, rule_index| {
        if (rule.prelude or rule.parameters.len != 0 or rule.capability == .group) continue;
        for (source.instantiations) |instance| {
            if (instance.rule != rule_index or instance.template or instance.arguments.len != 0) continue;
            try builder.visit(instance.value);
            const name = try identifiers.allocate(rule.name);
            const codec_base = try std.fmt.allocPrint(a, "{s}Codec", .{name});
            const codec_name = try identifiers.allocate(codec_base);
            try exports.append(a, .{ .name = name, .codec_name = codec_name, .node = instance.value });
            break;
        }
    }
    return .{ .arena = arena, .source = source, .reachable = builder.reachable, .fields = builder.fields, .exports = try exports.toOwnedSlice(a) };
}

const Builder = struct {
    allocator: std.mem.Allocator,
    source: *const model.Model,
    colors: []u2,
    reachable: []bool,
    fields: [][]const Field,
    failed_node: ?*?model.NodeId,

    fn fail(self: *Builder, id: model.NodeId, err: Error) Error {
        if (self.failed_node) |pointer| pointer.* = id;
        return err;
    }

    fn visit(self: *Builder, id: model.NodeId) Error!void {
        if (id >= self.source.nodes.len) return self.fail(id, error.InvalidModel);
        if (self.colors[id] == 1) return self.fail(id, error.UnsupportedRecursion);
        if (self.colors[id] == 2) return;
        self.colors[id] = 1;
        self.reachable[id] = true;
        const node = self.source.node(id);
        if (node.capability != .type) return self.fail(id, error.InvalidModel);
        switch (node.data) {
            .reference => |child| try self.visit(child),
            .choice => |children| for (children) |child| try self.visit(child),
            .literal, .range => {},
            .array, .map => |group| {
                var fields: std.ArrayList(Field) = .empty;
                var identifiers = names.Names{ .allocator = self.allocator };
                defer identifiers.deinit();
                try self.flatten(group, node.data == .map, &fields, &identifiers, 0);
                self.fields[id] = try fields.toOwnedSlice(self.allocator);
                for (self.fields[id]) |field| {
                    try self.visit(field.value);
                    if (field.key) |key| try self.visit(key);
                }
            },
            .head => |head| {
                if (head.number_type) |child| {
                    if (head.major != 6) return self.fail(id, error.UnsupportedHead);
                    try self.visit(child);
                }
                if (head.content) |child| {
                    if (head.major != 6) return self.fail(id, error.UnsupportedHead);
                    try self.visit(child);
                }
            },
            .control => |control| {
                switch (control.operator) {
                    .regexp, .cborseq => return self.fail(id, error.UnsupportedControl),
                    .size => {
                        _ = sizeMaximum(self.source, control.controller) catch |err| return self.fail(id, err);
                    },
                    .lt, .le, .gt, .ge => {
                        const value = self.literal(control.controller) orelse return self.fail(id, error.UnsupportedControl);
                        if (value != .integer and value != .float) return self.fail(id, error.UnsupportedControl);
                    },
                    .eq, .ne => if (self.literal(control.controller) == null and self.simple(control.controller) == null) return self.fail(id, error.UnsupportedControl),
                    else => {},
                }
                try self.visit(control.target);
                try self.visit(control.controller);
            },
            .parameter, .range_expression, .unwrap, .enumeration => return self.fail(id, error.UnresolvedTemplate),
            .group, .sequence, .entry => return self.fail(id, error.InvalidModel),
        }
        self.colors[id] = 2;
    }

    fn literal(self: *const Builder, initial: model.NodeId) ?model.Literal {
        var id = initial;
        for (0..self.source.nodes.len) |_| {
            switch (self.source.node(id).data) {
                .literal => |value| return value,
                .head => |head| {
                    const number = head.number orelse return null;
                    if (number >= 24) return null;
                    if (head.major == 0) return .{ .integer = number };
                    if (head.major == 1) return .{ .integer = -1 - @as(i65, number) };
                    return null;
                },
                .range => |range| {
                    if (!range.inclusive or std.meta.activeTag(range.lower) != std.meta.activeTag(range.upper)) return null;
                    return switch (range.lower) {
                        .integer => |number| if (number == range.upper.integer) .{ .integer = number } else null,
                        .float => |number| if (number == range.upper.float) .{ .float = number } else null,
                    };
                },
                .reference => |child| id = child,
                .choice => |children| if (children.len == 1) {
                    id = children[0];
                } else return null,
                else => return null,
            }
        }
        return null;
    }

    fn simple(self: *const Builder, initial: model.NodeId) ?u8 {
        var id = initial;
        for (0..self.source.nodes.len) |_| {
            switch (self.source.node(id).data) {
                .reference => |child| id = child,
                .choice => |children| if (children.len == 1) {
                    id = children[0];
                } else return null,
                .head => |head| {
                    const number = head.number orelse return null;
                    return if (head.major == 7 and (number < 24 or number >= 32) and number <= 255) @intCast(number) else null;
                },
                else => return null,
            }
        }
        return null;
    }

    fn keysEqual(self: *const Builder, a: model.NodeId, b: model.NodeId) bool {
        if (self.literal(a)) |first| {
            const second = self.literal(b) orelse return false;
            return literalEql(first, second);
        }
        return self.simple(a).? == self.simple(b);
    }

    fn flatten(self: *Builder, id: model.NodeId, is_map: bool, fields: *std.ArrayList(Field), identifiers: *names.Names, depth: usize) Error!void {
        if (depth > self.source.nodes.len) return self.fail(id, error.UnsupportedRecursion);
        switch (self.source.node(id).data) {
            .reference => |child| try self.flatten(child, is_map, fields, identifiers, depth + 1),
            .group => |children| {
                if (children.len != 1) return self.fail(id, error.UnsupportedGroupChoice);
                try self.flatten(children[0], is_map, fields, identifiers, depth + 1);
            },
            .sequence => |children| for (children) |child| try self.flatten(child, is_map, fields, identifiers, depth + 1),
            .entry => |entry| {
                if (entry.splice) {
                    if (entry.occurrence.min != 1 or entry.occurrence.max != 1) return self.fail(id, error.UnsupportedGroupOccurrence);
                    return self.flatten(entry.value, is_map, fields, identifiers, depth + 1);
                }
                var label: ?[]const u8 = null;
                if (entry.key) |key| {
                    if (self.literal(key.value)) |value| {
                        if (value == .text) label = value.text;
                    } else if (is_map and self.simple(key.value) == null) return self.fail(id, error.UnsupportedMapKey);
                } else if (is_map) return self.fail(id, error.UnsupportedMapKey);
                if (is_map) {
                    if (entry.occurrence.max == null or entry.occurrence.max.? > 1) return self.fail(id, error.UnsupportedMapOccurrence);
                    for (fields.items) |previous| {
                        if (self.keysEqual(previous.key.?, entry.key.?.value)) return self.fail(id, error.UnsupportedMapKey);
                    }
                }
                const fallback = try std.fmt.allocPrint(self.allocator, "field_{d}", .{fields.items.len});
                try fields.append(self.allocator, .{
                    .name = try identifiers.allocate(label orelse fallback),
                    .value = entry.value,
                    .key = if (is_map) entry.key.?.value else null,
                    .occurrence = entry.occurrence,
                });
            },
            else => return self.fail(id, error.InvalidModel),
        }
    }
};

fn literalEql(a: model.Literal, b: model.Literal) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .integer => |value| value == b.integer,
        .float => |value| value == b.float or (std.math.isNan(value) and std.math.isNan(b.float) and (@as(u64, @bitCast(value)) & 0x000fffffffffffff) == (@as(u64, @bitCast(b.float)) & 0x000fffffffffffff)),
        .text => |value| std.mem.eql(u8, value, b.text),
        .bytes => |value| std.mem.eql(u8, value, b.bytes),
    };
}

test "planning preserves cardinalities with PascalCase exports and snake_case fields" {
    const parser = @import("parser.zig");
    const semantic = @import("semantic.zig");
    const diagnostics = @import("diagnostics.zig");
    var messages = diagnostics.Diagnostics.init(std.testing.allocator);
    defer messages.deinit();
    var ast = try parser.parse(std.testing.allocator, .{ .name = "plan", .text = "my-packet = { userName: tstr, ? item-count: uint }\nmy.packet = uint\nmy-packet-codec = tstr" }, &messages);
    defer ast.deinit();
    var normalized = (try semantic.analyze(std.testing.allocator, &ast, &messages, .{})).?;
    defer normalized.deinit();
    var result = try build(std.testing.allocator, &normalized, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.exports.len);
    try std.testing.expectEqualStrings("MyPacket", result.exports[0].name);
    try std.testing.expectEqualStrings("MyPacketCodec", result.exports[0].codec_name);
    try std.testing.expectEqualStrings("MyPacket2", result.exports[1].name);
    try std.testing.expectEqualStrings("MyPacket2Codec", result.exports[1].codec_name);
    try std.testing.expectEqualStrings("MyPacketCodec2", result.exports[2].name);
    try std.testing.expectEqualStrings("MyPacketCodec2Codec", result.exports[2].codec_name);
    var root = result.exports[0].node;
    while (true) {
        switch (normalized.node(root).data) {
            .reference => |child| root = child,
            .choice => |children| {
                try std.testing.expectEqual(@as(usize, 1), children.len);
                root = children[0];
            },
            else => break,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), result.fields[root].len);
    try std.testing.expectEqualStrings("user_name", result.fields[root][0].name);
    try std.testing.expectEqualStrings("item_count", result.fields[root][1].name);
    try std.testing.expectEqual(@as(u64, 0), result.fields[root][1].occurrence.min);
    try std.testing.expectEqual(@as(?u64, 1), result.fields[root][1].occurrence.max);
}

test "unsupported exact mappings identify their normalized source node" {
    const parser = @import("parser.zig");
    const semantic = @import("semantic.zig");
    const diagnostics = @import("diagnostics.zig");
    const cases = [_]struct { schema: []const u8, failure: Error }{
        .{ .schema = "x = { * tstr => uint }", .failure = error.UnsupportedMapKey },
        .{ .schema = "x = tstr .regexp \"a+\"", .failure = error.UnsupportedControl },
        .{ .schema = "x = [x]", .failure = error.UnsupportedRecursion },
    };
    for (cases) |case| {
        var messages = diagnostics.Diagnostics.init(std.testing.allocator);
        defer messages.deinit();
        var ast = try parser.parse(std.testing.allocator, .{ .name = "unsupported", .text = case.schema }, &messages);
        defer ast.deinit();
        var normalized = (try semantic.analyze(std.testing.allocator, &ast, &messages, .{})).?;
        defer normalized.deinit();
        var failed: ?model.NodeId = null;
        try std.testing.expectError(case.failure, build(std.testing.allocator, &normalized, &failed));
        try std.testing.expect(failed != null);
        try std.testing.expect(!normalized.node(failed.?).origin.prelude);
    }
}

test "size ranges retain exact finite upper bounds and native scalar domains" {
    const parser = @import("parser.zig");
    const semantic = @import("semantic.zig");
    const diagnostics = @import("diagnostics.zig");
    var messages = diagnostics.Diagnostics.init(std.testing.allocator);
    defer messages.deinit();
    var ast = try parser.parse(std.testing.allocator, .{ .name = "bounds", .text = "payload = bstr .size (1...4)\nflag = bool\ncount = int" }, &messages);
    defer ast.deinit();
    var normalized = (try semantic.analyze(std.testing.allocator, &ast, &messages, .{})).?;
    defer normalized.deinit();
    var result = try build(std.testing.allocator, &normalized, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.exports.len);
    try std.testing.expectEqual(Scalar.boolean, scalar(&normalized, result.exports[1].node).?);
    try std.testing.expectEqual(Scalar.integer, scalar(&normalized, result.exports[2].node).?);
    var found = false;
    for (normalized.nodes, 0..) |node, id| {
        if (!result.reachable[id] or node.data != .control or node.data.control.operator != .size) continue;
        try std.testing.expectEqual(@as(?u64, 3), try sizeMaximum(&normalized, node.data.control.controller));
        found = true;
    }
    try std.testing.expect(found);
}
