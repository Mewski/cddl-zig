const std = @import("std");

pub const Operator = enum {
    size,
    bits,
    regexp,
    cbor,
    cborseq,
    within,
    @"and",
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    default,
};
pub const Controller = enum { type, unsigned, numeric, text };
pub const Definition = struct {
    name: []const u8,
    operator: Operator,
    controller: Controller,
};

/// RFC 8610 controls only. Later control vocabularies must be explicitly enabled
/// by a future language extension, never silently treated as annotations.
pub const registry = [_]Definition{
    .{ .name = "size", .operator = .size, .controller = .unsigned },
    .{ .name = "bits", .operator = .bits, .controller = .unsigned },
    .{ .name = "regexp", .operator = .regexp, .controller = .text },
    .{ .name = "cbor", .operator = .cbor, .controller = .type },
    .{ .name = "cborseq", .operator = .cborseq, .controller = .type },
    .{ .name = "within", .operator = .within, .controller = .type },
    .{ .name = "and", .operator = .@"and", .controller = .type },
    .{ .name = "lt", .operator = .lt, .controller = .numeric },
    .{ .name = "le", .operator = .le, .controller = .numeric },
    .{ .name = "gt", .operator = .gt, .controller = .numeric },
    .{ .name = "ge", .operator = .ge, .controller = .numeric },
    .{ .name = "eq", .operator = .eq, .controller = .type },
    .{ .name = "ne", .operator = .ne, .controller = .type },
    .{ .name = "default", .operator = .default, .controller = .type },
};

pub fn lookup(name: []const u8) ?Definition {
    for (registry) |definition| {
        if (std.mem.eql(u8, name, definition.name)) return definition;
    }
    return null;
}

test "control vocabulary is explicit" {
    try std.testing.expectEqual(Operator.@"and", lookup("and").?.operator);
    try std.testing.expect(lookup("feature") == null);
    try std.testing.expect(lookup("cat") == null);
}
