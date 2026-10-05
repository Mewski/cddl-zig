const std = @import("std");
const syntax = @import("ast.zig");
const controls = @import("controls.zig");

pub const NodeId = u32;
pub const RuleId = u32;
pub const Capability = enum { type, group };
pub const Origin = struct {
    span: syntax.Span,
    prelude: bool = false,
};
pub const Number = union(enum) { integer: i65, float: f64 };
pub const Literal = union(enum) {
    integer: i65,
    float: f64,
    text: []const u8,
    bytes: []const u8,
};
pub const Occurrence = struct { min: u64 = 1, max: ?u64 = 1 };
pub const Key = struct { value: NodeId, cut: bool, origin: Origin };
pub const Entry = struct {
    occurrence: Occurrence,
    key: ?Key,
    value: NodeId,
    /// Group-valued entries splice a sequence; type-valued entries consume one item.
    splice: bool,
};
pub const Range = struct { lower: Number, upper: Number, inclusive: bool };
pub const Head = struct {
    major: ?u3,
    /// CBOR additional information for majors 0..5, tag number for major 6,
    /// or RFC 9682 simple-value/float selector for major 7.
    number: ?u64 = null,
    number_type: ?NodeId = null,
    content: ?NodeId = null,
};
pub const Control = struct { operator: controls.Operator, target: NodeId, controller: NodeId };
pub const Node = struct {
    origin: Origin,
    capability: Capability,
    data: union(enum) {
        /// Empty choice: the empty set of matching data items (not an empty group).
        choice: []const NodeId,
        literal: Literal,
        reference: NodeId,
        range: Range,
        control: Control,
        array: NodeId,
        /// A generic template's numeric endpoints, folded on concrete instantiation.
        range_expression: struct { lower: NodeId, upper: NodeId, inclusive: bool },
        /// A generic template's parameter-dependent unwrap.
        unwrap: NodeId,
        /// Parameter-dependent group enumeration in a generic template.
        enumeration: NodeId,
        map: NodeId,
        /// Ordered alternatives of group expressions; an empty slice matches nothing.
        group: []const NodeId,
        sequence: []const NodeId,
        entry: Entry,
        head: Head,
        /// Only generic template instances contain parameters; concrete instances do not.
        parameter: struct { rule: RuleId, index: u32 },
    },
};
pub const Rule = struct {
    name: []const u8,
    parameters: []const []const u8,
    origins: []const Origin,
    /// Template capability; a concrete instantiation's node is authoritative.
    capability: Capability,
    socket: bool,
    prelude: bool,
};
pub const Instantiation = struct {
    rule: RuleId,
    arguments: []const NodeId,
    value: NodeId,
    template: bool,
};

/// Immutable normalized semantic graph. All storage, including names and literals,
/// is owned here; the source AST may be destroyed immediately after analysis.
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const Node,
    rules: []const Rule,
    instantiations: []const Instantiation,
    root: NodeId,
    root_rule: RuleId,

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn node(self: *const Model, id: NodeId) *const Node {
        return &self.nodes[id];
    }
};
