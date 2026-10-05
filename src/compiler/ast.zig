const std = @import("std");
const source = @import("source.zig");
pub const NodeId = u32;
pub const Source = source.Source;
pub const Span = source.Span;

pub const Literal = union(enum) {
    unsigned: u64,
    negative: i65,
    float: struct { lexeme: []const u8, value: f64 },
    text: []const u8,
    bytes: []const u8,
};
pub const Reference = struct { name: []const u8, arguments: []const NodeId };
pub const Occurrence = struct {
    min: u64 = 1,
    max: ?u64 = 1,
    explicit: bool = false,
};
pub const MemberKey = struct {
    value: NodeId,
    kind: enum { bareword, literal, type },
    cut: bool = false,
};
pub const Entry = struct { occurrence: Occurrence, key: ?MemberKey, value: NodeId };
pub const GroupChoice = struct {
    entries: []const NodeId,
    has_comma: bool,
    trailing_comma: bool,
};
pub const Range = struct { lower: NodeId, upper: NodeId, inclusive: bool };
pub const Control = struct { target: NodeId, controller: NodeId, name: []const u8 };
pub const Head = struct {
    major: ?u3,
    number: ?u64 = null,
    number_type: ?NodeId = null,
    content: ?NodeId = null,
};
pub const Node = struct {
    span: Span,
    data: union(enum) {
        literal: Literal,
        reference: Reference,
        choice: []const NodeId,
        range: Range,
        control: Control,
        array: NodeId,
        map: NodeId,
        parenthesized: NodeId,
        group: []const NodeId,
        group_choice: GroupChoice,
        entry: Entry,
        unwrap: Reference,
        enumeration: NodeId,
        head: Head,
    },
};
pub const Rule = struct {
    name: []const u8,
    parameters: []const []const u8,
    assignment: enum { define, type_extend, group_extend },
    value: NodeId,
    rhs_kind: enum { type_capable, group_only },
    span: Span,
};

/// Owns all AST storage and decoded literals; source text remains borrowed.
pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    source: Source,
    nodes: []const Node,
    rules: []const Rule,

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn node(self: *const Ast, id: NodeId) *const Node {
        return &self.nodes[id];
    }

    pub fn lexeme(self: *const Ast, id: NodeId) []const u8 {
        return self.source.slice(self.nodes[id].span);
    }
};
