const std = @import("std");
const syntax = @import("ast.zig");
const diagnostic = @import("diagnostics.zig");
const parser = @import("parser.zig");
const prelude = @import("prelude.zig");
const controls = @import("controls.zig");
pub const model = @import("model.zig");

pub const Options = struct {
    root: ?[]const u8 = null,
    max_instantiations: usize = 4096,
    max_depth: usize = 512,
};
pub const AnalyzeError = error{OutOfMemory};
const Failure = AnalyzeError || error{InvalidSemantic};
const Id = model.NodeId;
const RuleId = model.RuleId;
const Origin = model.Origin;
const Capability = model.Capability;
const NodeData = @FieldType(model.Node, "data");
const Part = struct { tree: *const syntax.Ast, rule: usize, builtin: bool };
const Symbol = struct {
    name: []const u8,
    parts: std.ArrayList(Part) = .empty,
    parameters: []const []const u8,
    capability: Capability = .type,
    socket: bool,
    builtin: bool,
};
const Environment = struct { arguments: []const Id };

/// Semantic errors are reported through diagnostics and return null. Allocation
/// failures remain errors. The result borrows nothing from the AST or options.
pub fn analyze(allocator: std.mem.Allocator, tree: *const syntax.Ast, diagnostics: *diagnostic.Diagnostics, options: Options) AnalyzeError!?model.Model {
    if (diagnostics.hasErrors()) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var builtin = parser.parse(allocator, .{ .name = "RFC 8610 prelude", .text = prelude.source }, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSyntax => {
            arena.deinit();
            return null;
        },
    };
    defer builtin.deinit();
    var analyzer = Analyzer{ .allocator = arena.allocator(), .diagnostics = diagnostics, .options = options };
    const root = analyzer.run(tree, &builtin) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSemantic => {
            arena.deinit();
            return null;
        },
    };
    if (diagnostics.hasErrors()) {
        arena.deinit();
        return null;
    }
    return .{
        .arena = arena,
        .nodes = analyzer.nodes.items,
        .rules = analyzer.rules.items,
        .instantiations = analyzer.instances.items,
        .root = root.value,
        .root_rule = root.rule,
    };
}

const Analyzer = struct {
    allocator: std.mem.Allocator,
    diagnostics: *diagnostic.Diagnostics,
    options: Options,
    symbols: std.ArrayList(Symbol) = .empty,
    names: std.StringHashMapUnmanaged(RuleId) = .empty,
    nodes: std.ArrayList(model.Node) = .empty,
    rules: std.ArrayList(model.Rule) = .empty,
    instances: std.ArrayList(model.Instantiation) = .empty,
    dependency_marks: std.ArrayList(u32) = .empty,
    dependency_epoch: u32 = 0,
    depth: usize = 0,

    fn fail(self: *Analyzer, code: diagnostic.Code, source: Origin, message: []const u8) Failure {
        try self.diagnostics.addFrom(code, source.span, message, if (source.prelude) .prelude else .input);
        return error.InvalidSemantic;
    }

    fn origin(part: Part, id: syntax.NodeId) Origin {
        return .{ .span = part.tree.node(id).span, .prelude = part.builtin };
    }

    fn ruleOrigin(part: Part) Origin {
        return .{ .span = part.tree.rules[part.rule].span, .prelude = part.builtin };
    }

    fn add(self: *Analyzer, source: Origin, capability: Capability, data: @FieldType(model.Node, "data")) Failure!Id {
        if (self.nodes.items.len >= std.math.maxInt(Id)) return self.fail(.node_limit, source, "normalized model exceeds the node index domain");
        const id: Id = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .origin = source, .capability = capability, .data = data });
        try self.dependency_marks.append(self.allocator, 0);
        return id;
    }

    fn run(self: *Analyzer, tree: *const syntax.Ast, builtin: *const syntax.Ast) Failure!struct { rule: RuleId, value: Id } {
        try self.collect(tree, false);
        try self.collect(builtin, true);
        try self.resolveCapabilities();
        for (self.symbols.items, 0..) |symbol, index| {
            const rule_id: RuleId = @intCast(index);
            var origins: std.ArrayList(Origin) = .empty;
            for (symbol.parts.items) |part| {
                try origins.append(self.allocator, ruleOrigin(part));
                try self.validate(part, part.tree.rules[part.rule].value, rule_id);
            }
            var parameters: std.ArrayList([]const u8) = .empty;
            for (symbol.parameters) |parameter| try parameters.append(self.allocator, try self.allocator.dupe(u8, parameter));
            try self.rules.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, symbol.name),
                .parameters = try parameters.toOwnedSlice(self.allocator),
                .origins = try origins.toOwnedSlice(self.allocator),
                .capability = symbol.capability,
                .socket = symbol.socket,
                .prelude = symbol.builtin,
            });
        }
        var selected: ?RuleId = null;
        if (self.options.root) |name| {
            selected = self.names.get(name);
            if (selected == null) return self.fail(.unknown_name, .{ .span = .{ .start = 0, .end = 0 } }, "selected root rule does not exist");
        } else {
            for (self.symbols.items, 0..) |symbol, index| {
                if (!symbol.builtin) {
                    selected = @intCast(index);
                    break;
                }
            }
        }
        const root_rule = selected orelse return self.fail(.invalid_schema, .{ .span = .{ .start = 0, .end = 0 } }, "schema has no root rule");
        const root_symbol = self.symbols.items[root_rule];
        if (root_symbol.capability != .type) return self.fail(.invalid_schema, ruleOrigin(root_symbol.parts.items[0]), "root rule must describe a type, not a group");
        if (root_symbol.parameters.len != 0) return self.fail(.invalid_schema, ruleOrigin(root_symbol.parts.items[0]), "root rule requires generic arguments");
        for (self.symbols.items, 0..) |symbol, index| {
            const rule_id: RuleId = @intCast(index);
            const args = try self.allocator.alloc(Id, symbol.parameters.len);
            for (args, 0..) |*argument, parameter| argument.* = try self.add(ruleOrigin(symbol.parts.items[0]), .type, .{ .parameter = .{ .rule = rule_id, .index = @intCast(parameter) } });
            _ = try self.instantiate(rule_id, args, args.len != 0, ruleOrigin(symbol.parts.items[0]));
        }
        const root = try self.instantiate(root_rule, &.{}, false, ruleOrigin(root_symbol.parts.items[0]));
        try self.normalizeDerived();
        try self.resolveModelCapabilities();
        if (self.nodes.items[root].capability != .type) return self.fail(.invalid_schema, ruleOrigin(root_symbol.parts.items[0]), "selected root instantiates to a group rather than a type");
        try self.checkProgress();
        try self.checkMaps();
        return .{ .rule = root_rule, .value = root };
    }

    fn collect(self: *Analyzer, tree: *const syntax.Ast, builtin: bool) Failure!void {
        for (tree.rules, 0..) |rule, index| {
            const part = Part{ .tree = tree, .rule = index, .builtin = builtin };
            const socket = std.mem.startsWith(u8, rule.name, "$");
            if (socket and rule.assignment == .define) return self.fail(.invalid_schema, ruleOrigin(part), "socket plugs must use '/=' for types or '//=' for groups");
            if (self.names.get(rule.name)) |id| {
                const symbol = &self.symbols.items[id];
                if (rule.parameters.len != symbol.parameters.len) return self.fail(.invalid_schema, ruleOrigin(part), "augmentation changes generic parameter arity");
                try symbol.parts.append(self.allocator, part);
            } else {
                const id: RuleId = @intCast(self.symbols.items.len);
                var symbol = Symbol{ .name = rule.name, .parameters = rule.parameters, .socket = socket, .builtin = builtin };
                try symbol.parts.append(self.allocator, part);
                try self.symbols.append(self.allocator, symbol);
                try self.names.put(self.allocator, rule.name, id);
            }
            for (rule.parameters, 0..) |parameter, parameter_index| {
                for (rule.parameters[0..parameter_index]) |previous| {
                    if (std.mem.eql(u8, parameter, previous)) return self.fail(.invalid_schema, ruleOrigin(part), "generic parameter is declared more than once");
                }
            }
        }
    }

    fn resolveCapabilities(self: *Analyzer) Failure!void {
        for (self.symbols.items) |*symbol| {
            var type_extension = false;
            var group_extension = false;
            for (symbol.parts.items) |part| {
                const rule = part.tree.rules[part.rule];
                type_extension = type_extension or rule.assignment == .type_extend;
                group_extension = group_extension or rule.assignment == .group_extend;
                if (rule.rhs_kind == .group_only) symbol.capability = .group;
            }
            if (type_extension and group_extension) return self.fail(.invalid_schema, ruleOrigin(symbol.parts.items[0]), "rule mixes type and group augmentation");
            if (group_extension or std.mem.startsWith(u8, symbol.name, "$$")) symbol.capability = .group;
            if (symbol.socket and !std.mem.startsWith(u8, symbol.name, "$$") and symbol.capability == .group) return self.fail(.invalid_schema, ruleOrigin(symbol.parts.items[0]), "single-dollar socket must be a type socket");
        }
        var changed = true;
        while (changed) {
            changed = false;
            for (self.symbols.items, 0..) |symbol, index| {
                if (symbol.capability == .group) continue;
                for (symbol.parts.items) |part| {
                    if (!self.typeCapable(part, part.tree.rules[part.rule].value, 0)) {
                        self.symbols.items[index].capability = .group;
                        changed = true;
                        break;
                    }
                }
            }
        }
        for (self.symbols.items) |symbol| {
            for (symbol.parts.items) |part| {
                const rule = part.tree.rules[part.rule];
                if (rule.assignment == .type_extend and symbol.capability != .type) return self.fail(.invalid_schema, ruleOrigin(part), "type augmentation targets a group rule");
            }
        }
    }

    fn typeCapable(self: *Analyzer, part: Part, id: syntax.NodeId, depth: usize) bool {
        if (depth >= self.options.max_depth) return false;
        return switch (part.tree.node(id).data) {
            .reference => |reference| blk: {
                for (part.tree.rules[part.rule].parameters) |name| if (std.mem.eql(u8, name, reference.name)) break :blk true;
                const target = self.names.get(reference.name) orelse break :blk !std.mem.startsWith(u8, reference.name, "$$");
                break :blk self.symbols.items[target].capability == .type;
            },
            .parenthesized => |group_id| blk: {
                const alternatives = part.tree.node(group_id).data.group;
                if (alternatives.len != 1) break :blk false;
                const sequence = part.tree.node(alternatives[0]).data.group_choice;
                if (sequence.has_comma or sequence.entries.len != 1) break :blk false;
                const entry = part.tree.node(sequence.entries[0]).data.entry;
                break :blk entry.key == null and !entry.occurrence.explicit and self.typeCapable(part, entry.value, depth + 1);
            },
            .unwrap => |reference| blk: {
                for (part.tree.rules[part.rule].parameters) |parameter| if (std.mem.eql(u8, parameter, reference.name)) break :blk true;
                break :blk self.unwrapCapability(reference.name, depth + 1);
            },
            .entry, .group, .group_choice => false,
            else => true,
        };
    }

    fn unwrapCapability(self: *Analyzer, name: []const u8, depth: usize) bool {
        if (depth >= self.options.max_depth) return false;
        const symbol = self.symbols.items[self.names.get(name) orelse return true];
        if (symbol.parts.items.len != 1) return true;
        const part = symbol.parts.items[0];
        return switch (part.tree.node(part.tree.rules[part.rule].value).data) {
            .array, .map => false,
            .reference => |reference| self.unwrapCapability(reference.name, depth + 1),
            else => true,
        };
    }

    fn validateReference(self: *Analyzer, part: Part, reference: syntax.Reference, source: Origin) Failure!void {
        for (part.tree.rules[part.rule].parameters) |parameter| {
            if (std.mem.eql(u8, parameter, reference.name)) {
                if (reference.arguments.len != 0) return self.fail(.invalid_schema, source, "generic parameter cannot itself receive arguments");
                return;
            }
        }
        if (self.names.get(reference.name)) |target| {
            if (self.symbols.items[target].parameters.len != reference.arguments.len) return self.fail(.invalid_schema, source, "generic argument count does not match declaration");
        } else if (std.mem.startsWith(u8, reference.name, "$")) {
            if (reference.arguments.len != 0) return self.fail(.invalid_schema, source, "undeclared socket cannot receive generic arguments");
        } else return self.fail(.unknown_name, source, "reference names an unknown rule or parameter");
    }

    fn validate(self: *Analyzer, part: Part, id: syntax.NodeId, rule: RuleId) Failure!void {
        if (self.depth >= self.options.max_depth) return self.fail(.nesting_limit, origin(part, id), "semantic traversal nesting limit exceeded");
        self.depth += 1;
        defer self.depth -= 1;
        const node = part.tree.node(id);
        switch (node.data) {
            .reference, .unwrap => |reference| {
                try self.validateReference(part, reference, origin(part, id));
                for (reference.arguments) |argument| try self.validate(part, argument, rule);
            },
            .choice, .group => |children| for (children) |child| try self.validate(part, child, rule),
            .range => |range| {
                try self.validate(part, range.lower, rule);
                try self.validate(part, range.upper, rule);
            },
            .control => |control| {
                if (controls.lookup(control.name) == null) return self.fail(.unsupported_extension, origin(part, id), "control operator is not in the supported RFC 8610 vocabulary");
                try self.validate(part, control.target, rule);
                try self.validate(part, control.controller, rule);
            },
            .array, .map, .parenthesized, .enumeration => |child| try self.validate(part, child, rule),
            .group_choice => |choice| for (choice.entries) |child| try self.validate(part, child, rule),
            .entry => |entry| {
                if (entry.key) |key| if (key.kind != .bareword) try self.validate(part, key.value, rule);
                try self.validate(part, entry.value, rule);
            },
            .head => |head| {
                if (head.number_type) |child| try self.validate(part, child, rule);
                if (head.content) |child| try self.validate(part, child, rule);
            },
            .literal => {},
        }
    }

    fn equivalent(self: *const Analyzer, left: Id, right: Id, depth: usize) bool {
        if (left == right) return true;
        if (depth >= self.options.max_depth) return false;
        const a = self.nodes.items[left];
        const b = self.nodes.items[right];
        if (a.data == .reference) return self.equivalent(a.data.reference, right, depth + 1);
        if (b.data == .reference) return self.equivalent(left, b.data.reference, depth + 1);
        if (std.meta.activeTag(a.data) != std.meta.activeTag(b.data)) return false;
        return switch (a.data) {
            .literal => |value| literalEqual(value, b.data.literal),
            .parameter => |parameter| parameter.rule == b.data.parameter.rule and parameter.index == b.data.parameter.index,
            .head => |head| head.major == b.data.head.major and head.number == b.data.head.number and self.optionalEquivalent(head.number_type, b.data.head.number_type, depth) and self.optionalEquivalent(head.content, b.data.head.content, depth),
            .array => |child| self.equivalent(child, b.data.array, depth + 1),
            .map => |child| self.equivalent(child, b.data.map, depth + 1),
            .choice, .group, .sequence => |children| blk: {
                const other = switch (b.data) {
                    .choice, .group, .sequence => |values| values,
                    else => unreachable,
                };
                if (children.len != other.len) break :blk false;
                for (children, other) |child, counterpart| if (!self.equivalent(child, counterpart, depth + 1)) break :blk false;
                break :blk true;
            },
            .entry => |entry| blk: {
                const other = b.data.entry;
                if (entry.occurrence.min != other.occurrence.min or entry.occurrence.max != other.occurrence.max or entry.splice != other.splice or (entry.key == null) != (other.key == null)) break :blk false;
                if (entry.key) |key| if (key.cut != other.key.?.cut or !self.equivalent(key.value, other.key.?.value, depth + 1)) break :blk false;
                break :blk self.equivalent(entry.value, other.value, depth + 1);
            },
            .control => |control| control.operator == b.data.control.operator and self.equivalent(control.target, b.data.control.target, depth + 1) and self.equivalent(control.controller, b.data.control.controller, depth + 1),
            .range => |range| numberOrder(range.lower, b.data.range.lower) == .eq and numberOrder(range.upper, b.data.range.upper) == .eq and range.inclusive == b.data.range.inclusive,
            .range_expression => |range| self.equivalent(range.lower, b.data.range_expression.lower, depth + 1) and self.equivalent(range.upper, b.data.range_expression.upper, depth + 1) and range.inclusive == b.data.range_expression.inclusive,
            .unwrap => |value| self.equivalent(value, b.data.unwrap, depth + 1),
            .enumeration => |value| self.equivalent(value, b.data.enumeration, depth + 1),
            .reference => unreachable,
        };
    }

    fn optionalEquivalent(self: *const Analyzer, left: ?Id, right: ?Id, depth: usize) bool {
        if (left) |value| return if (right) |other| self.equivalent(value, other, depth + 1) else false;
        return right == null;
    }

    fn argumentsEqual(self: *const Analyzer, left: []const Id, right: []const Id) bool {
        if (left.len != right.len) return false;
        for (left, right) |a, b| if (!self.equivalent(a, b, 0)) return false;
        return true;
    }

    fn instantiate(self: *Analyzer, rule_id: RuleId, arguments: []const Id, template: bool, source: Origin) Failure!Id {
        for (self.instances.items) |instance| {
            if (instance.rule == rule_id and instance.template == template and self.argumentsEqual(arguments, instance.arguments)) return instance.value;
        }
        if (self.instances.items.len >= self.options.max_instantiations) return self.fail(.node_limit, source, "generic instantiation limit exceeded");
        const symbol = self.symbols.items[rule_id];
        const args = try self.allocator.dupe(Id, arguments);
        const result = try self.add(source, symbol.capability, if (symbol.capability == .type) .{ .choice = &.{} } else .{ .group = &.{} });
        self.nodes.items[result].data = .{ .reference = result };
        try self.instances.append(self.allocator, .{ .rule = rule_id, .arguments = args, .value = result, .template = template });
        var alternatives: std.ArrayList(Id) = .empty;
        var definition: ?Id = null;
        var capability = symbol.capability;
        for (symbol.parts.items) |part| {
            const rule = part.tree.rules[part.rule];
            const value = try self.lower(part, rule.value, .{ .arguments = args }, if (symbol.capability == .group) .group else null);
            if (rule.assignment == .define) {
                if (definition) |previous| {
                    if (!self.equivalent(previous, value, 0)) return self.fail(.duplicate_rule, ruleOrigin(part), "rule has conflicting '=' definitions");
                    continue;
                }
                definition = value;
            }
            if (self.nodes.items[value].capability == .group) capability = .group;
            if (rule.assignment == .type_extend and capability == .group) return self.fail(.invalid_schema, ruleOrigin(part), "type augmentation instantiates to a group");
            try alternatives.append(self.allocator, value);
        }
        const values = try alternatives.toOwnedSlice(self.allocator);
        if (capability == .group) {
            for (values) |*value| {
                if (self.nodes.items[value.*].capability == .type) value.* = try self.add(self.nodes.items[value.*].origin, .group, .{ .entry = .{ .occurrence = .{}, .key = null, .value = value.*, .splice = false } });
            }
        }
        self.nodes.items[result].capability = capability;
        self.nodes.items[result].data = if (values.len == 1) .{ .reference = values[0] } else if (capability == .type) .{ .choice = values } else .{ .group = values };
        return result;
    }

    fn lowerReference(self: *Analyzer, part: Part, reference_value: syntax.Reference, environment: Environment, source: Origin) Failure!Id {
        for (part.tree.rules[part.rule].parameters, 0..) |name, index| {
            if (std.mem.eql(u8, name, reference_value.name)) return self.add(source, self.nodes.items[environment.arguments[index]].capability, .{ .reference = environment.arguments[index] });
        }
        const rule_id = self.names.get(reference_value.name) orelse {
            const capability: Capability = if (std.mem.startsWith(u8, reference_value.name, "$$")) .group else .type;
            return self.add(source, capability, if (capability == .type) .{ .choice = &.{} } else .{ .group = &.{} });
        };
        const args = try self.allocator.alloc(Id, reference_value.arguments.len);
        for (reference_value.arguments, args) |argument, *value| value.* = try self.lower(part, argument, environment, null);
        var template = false;
        for (args) |argument| template = template or self.parameterDependent(argument, 0);
        const value = try self.instantiate(rule_id, args, template, source);
        return self.add(source, self.nodes.items[value].capability, .{ .reference = value });
    }

    fn lower(self: *Analyzer, part: Part, id: syntax.NodeId, environment: Environment, expected: ?Capability) Failure!Id {
        if (self.depth >= self.options.max_depth) return self.fail(.nesting_limit, origin(part, id), "semantic lowering nesting limit exceeded");
        self.depth += 1;
        defer self.depth -= 1;
        const source = origin(part, id);
        const data = part.tree.node(id).data;
        const result: Id = switch (data) {
            .literal => |literal| try self.add(source, .type, .{ .literal = switch (literal) {
                .unsigned => |value| .{ .integer = value },
                .negative => |value| .{ .integer = value },
                .float => |value| .{ .float = value.value },
                .text => |value| .{ .text = try self.allocator.dupe(u8, value) },
                .bytes => |value| .{ .bytes = try self.allocator.dupe(u8, value) },
            } }),
            .reference => |value| try self.lowerReference(part, value, environment, source),
            .choice => |children| blk: {
                const values = try self.allocator.alloc(Id, children.len);
                for (children, values) |child, *value| value.* = try self.lower(part, child, environment, .type);
                break :blk try self.add(source, .type, .{ .choice = values });
            },
            .array, .map => |child| blk: {
                const group = try self.lower(part, child, environment, .group);
                break :blk try self.add(source, .type, if (data == .array) .{ .array = group } else .{ .map = group });
            },
            .parenthesized => |child| blk: {
                if (expected != .group and self.typeCapable(part, id, 0)) {
                    const sequence = part.tree.node(part.tree.node(child).data.group[0]).data.group_choice;
                    const value = try self.lower(part, part.tree.node(sequence.entries[0]).data.entry.value, environment, expected);
                    break :blk try self.add(source, self.nodes.items[value].capability, .{ .reference = value });
                }
                break :blk try self.lower(part, child, environment, .group);
            },
            .group => |children| blk: {
                const values = try self.allocator.alloc(Id, children.len);
                for (children, values) |child, *value| value.* = try self.lower(part, child, environment, .group);
                break :blk try self.add(source, .group, .{ .group = values });
            },
            .group_choice => |choice| blk: {
                const values = try self.allocator.alloc(Id, choice.entries.len);
                for (choice.entries, values) |child, *value| value.* = try self.lower(part, child, environment, .group);
                break :blk try self.add(source, .group, .{ .sequence = values });
            },
            .entry => |entry| blk: {
                if (entry.occurrence.max) |maximum| if (maximum < entry.occurrence.min) return self.fail(.invalid_occurrence, source, "occurrence maximum is less than its minimum");
                var key: ?model.Key = null;
                if (entry.key) |member| {
                    const value = if (member.kind == .bareword)
                        try self.add(origin(part, member.value), .type, .{ .literal = .{ .text = try self.allocator.dupe(u8, part.tree.node(member.value).data.reference.name) } })
                    else
                        try self.lower(part, member.value, environment, .type);
                    key = .{ .value = value, .cut = member.cut, .origin = origin(part, member.value) };
                }
                const value = try self.lower(part, entry.value, environment, if (key != null) .type else null);
                const capability = self.nodes.items[value].capability;
                break :blk try self.add(source, .group, .{ .entry = .{ .occurrence = .{ .min = entry.occurrence.min, .max = entry.occurrence.max }, .key = key, .value = value, .splice = capability == .group } });
            },
            .range => |range| try self.lowerRange(part, range, environment, source),
            .control => |control| try self.lowerControl(part, control, environment, source),
            .head => |head| blk: {
                var normalized = model.Head{ .major = head.major, .number = head.number };
                if (head.number_type) |child| normalized.number_type = try self.lower(part, child, environment, .type);
                if (head.content) |child| normalized.content = try self.lower(part, child, environment, .type);
                if (head.major == 7) {
                    if (normalized.number) |number| if (number > 255 or number == 24 or (number >= 28 and number <= 31)) return self.fail(.invalid_schema, source, "representation head denotes a reserved or invalid CBOR simple value");
                }
                if (head.major) |major| {
                    if (major < 6) {
                        if (head.number) |number| if (number > 31 or (number >= 28 and number <= 30) or (number == 31 and major < 2)) return self.fail(.invalid_schema, source, "representation head has invalid CBOR additional information");
                    }
                }
                break :blk try self.add(source, .type, .{ .head = normalized });
            },
            .unwrap => |reference_value| blk: {
                const target = try self.lowerReference(part, reference_value, environment, source);
                if (self.dereference(target) == null) {
                    const capability = expected orelse if (self.typeCapable(part, id, 0)) Capability.type else Capability.group;
                    break :blk try self.add(source, capability, .{ .unwrap = target });
                }
                break :blk try self.unwrapValue(target, expected, source, 0);
            },
            .enumeration => |child| blk: {
                const group = try self.lower(part, child, environment, .group);
                break :blk try self.add(source, .type, .{ .enumeration = group });
            },
        };
        if (expected == null or self.nodes.items[result].capability == expected) return result;
        if (expected == .type) return self.fail(.invalid_schema, source, "group-valued expression is used where a type is required");
        return self.add(source, .group, .{ .entry = .{ .occurrence = .{}, .key = null, .value = result, .splice = false } });
    }

    fn unwrapValue(self: *Analyzer, target: Id, expected: ?Capability, source: Origin, depth: usize) Failure!Id {
        if (depth >= self.options.max_depth) return self.fail(.nesting_limit, source, "unwrap expansion nesting limit exceeded");
        const resolved = self.dereference(target) orelse return self.fail(.invalid_schema, source, "unwrap target does not resolve to a finite container or tag");
        const data = self.nodes.items[resolved].data;
        const value = switch (data) {
            .array, .map => |group| group,
            .head => |head| if (head.major == 6) head.content orelse return self.fail(.invalid_schema, source, "cannot unwrap a tag without a content type") else return self.fail(.invalid_schema, source, "unwrap requires an array, map, or tagged type"),
            .parameter => return self.add(source, expected orelse .type, .{ .unwrap = target }),
            .unwrap => |inner| {
                if (self.parameterDependent(inner, 0)) return self.add(source, expected orelse .type, .{ .unwrap = target });
                const unwrapped = try self.unwrapValue(inner, null, source, depth + 1);
                return self.unwrapValue(unwrapped, expected, source, depth + 1);
            },
            .choice => |choices| {
                const values = try self.allocator.alloc(Id, choices.len);
                var capability = expected orelse Capability.type;
                for (choices, values) |choice, *result| {
                    result.* = try self.unwrapValue(choice, expected, source, depth + 1);
                    if (self.nodes.items[result.*].capability == .group) capability = .group;
                }
                if (capability == .group) {
                    for (values) |*result| {
                        if (self.nodes.items[result.*].capability == .type) result.* = try self.add(source, .group, .{ .entry = .{ .occurrence = .{}, .key = null, .value = result.*, .splice = false } });
                    }
                }
                return self.add(source, capability, if (capability == .type) .{ .choice = values } else .{ .group = values });
            },
            else => return self.fail(.invalid_schema, source, "unwrap requires an array, map, or tagged type"),
        };
        return self.add(source, self.nodes.items[value].capability, .{ .reference = value });
    }

    fn dereference(self: *const Analyzer, id: Id) ?Id {
        var current = id;
        var remaining = self.nodes.items.len;
        while (remaining != 0) : (remaining -= 1) {
            const data = self.nodes.items[current].data;
            if (data != .reference) return current;
            current = data.reference;
        }
        return null;
    }

    fn constant(self: *const Analyzer, id: Id) ?model.Literal {
        return self.constantDepth(id, 0);
    }

    fn constantDepth(self: *const Analyzer, id: Id, depth: usize) ?model.Literal {
        if (depth >= self.options.max_depth) return null;
        const resolved = self.dereference(id) orelse return null;
        return switch (self.nodes.items[resolved].data) {
            .literal => |value| value,
            .choice => |values| if (values.len == 1) self.constantDepth(values[0], depth + 1) else null,
            .range => |range| if (range.inclusive and numberOrder(range.lower, range.upper) == .eq) switch (range.lower) {
                .integer => |value| .{ .integer = value },
                .float => |value| .{ .float = value },
            } else null,
            .head => |head| if (head.number) |number| if (number < 24) switch (head.major orelse return null) {
                0 => .{ .integer = number },
                1 => .{ .integer = -1 - @as(i65, number) },
                else => null,
            } else null else null,
            else => null,
        };
    }

    fn lowerRange(self: *Analyzer, part: Part, range: syntax.Range, environment: Environment, source: Origin) Failure!Id {
        const lower_bound = try self.lower(part, range.lower, environment, .type);
        const upper_bound = try self.lower(part, range.upper, environment, .type);
        return self.add(source, .type, .{ .range_expression = .{ .lower = lower_bound, .upper = upper_bound, .inclusive = range.inclusive } });
    }

    fn normalizeRange(self: *Analyzer, lower_bound: Id, upper_bound: Id, inclusive: bool, source: Origin) Failure!NodeData {
        for ([_]Id{ lower_bound, upper_bound }) |bound| {
            if (self.parameterDependent(bound, 0)) continue;
            const value = self.constant(bound) orelse return self.fail(.invalid_schema, source, "range endpoint must resolve to a numeric constant");
            if (literalNumber(value) == null) return self.fail(.invalid_schema, source, "range endpoint is not numeric");
        }
        if (self.parameterDependent(lower_bound, 0) or self.parameterDependent(upper_bound, 0)) return .{ .range_expression = .{ .lower = lower_bound, .upper = upper_bound, .inclusive = inclusive } };
        const first = self.constant(lower_bound) orelse return self.fail(.invalid_schema, source, "range lower endpoint must resolve to a numeric constant");
        const last = self.constant(upper_bound) orelse return self.fail(.invalid_schema, source, "range upper endpoint must resolve to a numeric constant");
        const a = literalNumber(first) orelse return self.fail(.invalid_schema, source, "range lower endpoint is not numeric");
        const b = literalNumber(last) orelse return self.fail(.invalid_schema, source, "range upper endpoint is not numeric");
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return self.fail(.invalid_schema, source, "range endpoints must both be integers or both be floats");
        if ((a == .float and !std.math.isFinite(a.float)) or (b == .float and !std.math.isFinite(b.float))) return self.fail(.invalid_schema, source, "range endpoints must be finite");
        const order = numberOrder(a, b);
        if (order == .gt or (order == .eq and !inclusive)) return .{ .choice = &.{} };
        return .{ .range = .{ .lower = a, .upper = b, .inclusive = inclusive } };
    }

    fn domain(self: *const Analyzer, id: Id, expected: controls.Controller, depth: usize) bool {
        if (expected == .type) return true;
        if (depth >= self.options.max_depth) return false;
        const data = self.nodes.items[id].data;
        return switch (data) {
            .reference => |value| self.domain(value, expected, depth + 1),
            .literal => |value| switch (expected) {
                .unsigned => value == .integer and value.integer >= 0,
                .numeric => value == .integer or value == .float,
                .text => value == .text,
                .type => true,
            },
            .range => |range| switch (expected) {
                .unsigned => range.lower == .integer and range.upper == .integer and range.lower.integer >= 0,
                .numeric => true,
                else => false,
            },
            .head => |head| switch (expected) {
                .unsigned => head.major == 0,
                .numeric => head.major == 0 or head.major == 1 or (head.major == 7 and head.number != null and head.number.? >= 25 and head.number.? <= 27),
                .text => head.major == 3,
                .type => true,
            },
            .choice => |values| blk: {
                for (values) |value| if (!self.domain(value, expected, depth + 1)) break :blk false;
                break :blk true;
            },
            .control => |control| self.domain(control.target, expected, depth + 1),
            else => false,
        };
    }

    fn parameterDependent(self: *Analyzer, id: Id, _: usize) bool {
        self.dependency_epoch +%= 1;
        if (self.dependency_epoch == 0) {
            @memset(self.dependency_marks.items, 0);
            self.dependency_epoch = 1;
        }
        return self.visitParameters(id, 0);
    }

    fn visitParameters(self: *Analyzer, id: Id, depth: usize) bool {
        if (depth >= self.options.max_depth or self.dependency_marks.items[id] == self.dependency_epoch) return false;
        self.dependency_marks.items[id] = self.dependency_epoch;
        return switch (self.nodes.items[id].data) {
            .parameter => true,
            .reference, .array, .map, .unwrap, .enumeration => |value| self.visitParameters(value, depth + 1),
            .choice, .group, .sequence => |values| blk: {
                for (values) |value| if (self.visitParameters(value, depth + 1)) break :blk true;
                break :blk false;
            },
            .entry => |entry| self.visitParameters(entry.value, depth + 1) or (if (entry.key) |key| self.visitParameters(key.value, depth + 1) else false),
            .control => |control| self.visitParameters(control.target, depth + 1) or self.visitParameters(control.controller, depth + 1),
            .range_expression => |range| self.visitParameters(range.lower, depth + 1) or self.visitParameters(range.upper, depth + 1),
            .head => |head| (if (head.number_type) |value| self.visitParameters(value, depth + 1) else false) or (if (head.content) |value| self.visitParameters(value, depth + 1) else false),
            else => false,
        };
    }

    fn singleton(self: *const Analyzer, id: Id, depth: usize) bool {
        if (depth >= self.options.max_depth) return false;
        if (self.constant(id) != null) return true;
        return switch (self.nodes.items[id].data) {
            .reference => |value| self.singleton(value, depth + 1),
            .head => |head| if (head.major == 7) if (head.number) |number| number < 24 or number >= 32 else false else if (head.major == 6 and head.number != null and head.content != null) self.singleton(head.content.?, depth + 1) else false,
            .array, .map => |value| self.singleton(value, depth + 1),
            .choice, .group => |values| values.len == 1 and self.singleton(values[0], depth + 1),
            .sequence => |values| blk: {
                for (values) |value| if (!self.singleton(value, depth + 1)) break :blk false;
                break :blk true;
            },
            .entry => |entry| entry.occurrence.min == entry.occurrence.max and (entry.occurrence.max == 0 or (self.singleton(entry.value, depth + 1) and (if (entry.key) |key| self.singleton(key.value, depth + 1) else true))),
            .range => |range| range.inclusive and numberOrder(range.lower, range.upper) == .eq,
            else => false,
        };
    }

    fn onlyMajors(self: *const Analyzer, id: Id, mask: u8, depth: usize) bool {
        if (depth >= self.options.max_depth) return false;
        return switch (self.nodes.items[id].data) {
            .reference => |value| self.onlyMajors(value, mask, depth + 1),
            .literal => |literal| blk: {
                const major: u3 = switch (literal) {
                    .integer => |value| if (value >= 0) 0 else 1,
                    .bytes => 2,
                    .text => 3,
                    .float => 7,
                };
                break :blk mask & (@as(u8, 1) << major) != 0;
            },
            .head => |head| if (head.major) |major| mask & (@as(u8, 1) << major) != 0 else mask == 255,
            .range => |range| if (range.lower == .integer and range.upper == .integer) (range.lower.integer >= 0 or mask & 2 != 0) and (range.upper.integer < 0 or mask & 1 != 0) else mask & 128 != 0,
            .choice => |values| blk: {
                for (values) |value| if (!self.onlyMajors(value, mask, depth + 1)) break :blk false;
                break :blk true;
            },
            .control => |control| self.onlyMajors(control.target, mask, depth + 1),
            .array => mask & 16 != 0,
            .map => mask & 32 != 0,
            else => false,
        };
    }

    fn lowerControl(self: *Analyzer, part: Part, control: syntax.Control, environment: Environment, source: Origin) Failure!Id {
        const definition = controls.lookup(control.name) orelse return self.fail(.unsupported_extension, source, "control operator is not in the supported RFC 8610 vocabulary");
        const target = try self.lower(part, control.target, environment, .type);
        const controller = try self.lower(part, control.controller, environment, .type);
        return self.add(source, .type, .{ .control = .{ .operator = definition.operator, .target = target, .controller = controller } });
    }

    fn normalizeControl(self: *Analyzer, definition: controls.Definition, target: Id, controller: Id, source: Origin) Failure!NodeData {
        const symbolic_controller = self.parameterDependent(controller, 0);
        if (!symbolic_controller and !self.domain(controller, definition.controller, 0)) return self.fail(.invalid_schema, source, "control operand has an incompatible value domain");
        if (!self.parameterDependent(target, 0)) {
            const valid_target = switch (definition.operator) {
                .size => self.onlyMajors(target, 1 | 4 | 8, 0),
                .bits => self.onlyMajors(target, 1 | 4, 0),
                .regexp => self.domain(target, .text, 0),
                .cbor, .cborseq => self.onlyMajors(target, 4, 0),
                .lt, .le, .gt, .ge => self.domain(target, .numeric, 0),
                else => true,
            };
            if (!valid_target) return self.fail(.invalid_schema, source, "control operator is not defined for the target value domain");
        }
        if (!symbolic_controller) {
            switch (definition.operator) {
                .lt, .le, .gt, .ge => if (self.constant(controller) == null) return self.fail(.invalid_schema, source, "comparison control requires a single numeric constant"),
                .regexp => if (self.constant(controller) == null) return self.fail(.invalid_schema, source, "regexp control requires a constant text pattern"),
                .eq, .ne, .default => if (!self.singleton(controller, 0)) return self.fail(.invalid_schema, source, "equality or default controller must describe exactly one value"),
                else => {},
            }
        }
        if (self.constant(target)) |a| {
            if (self.constant(controller)) |b| {
                const matches: ?bool = switch (definition.operator) {
                    .eq => scalarEqual(a, b),
                    .ne => !scalarEqual(a, b),
                    .lt, .le, .gt, .ge => blk: {
                        const first = literalNumber(a) orelse break :blk null;
                        const last = literalNumber(b) orelse break :blk null;
                        const order = numberOrder(first, last);
                        break :blk switch (definition.operator) {
                            .lt => order == .lt,
                            .le => order != .gt,
                            .gt => order == .gt,
                            .ge => order != .lt,
                            else => unreachable,
                        };
                    },
                    .@"and", .within => literalEqual(a, b),
                    .size => blk: {
                        if (b != .integer or b.integer < 0) break :blk null;
                        break :blk switch (a) {
                            .text => |value| @as(i65, @intCast(value.len)) == b.integer,
                            .bytes => |value| @as(i65, @intCast(value.len)) == b.integer,
                            .integer => |value| if (value < 0) false else if (b.integer >= 8) true else @as(u64, @intCast(value)) < (@as(u64, 1) << @as(u6, @intCast(b.integer * 8))),
                            else => null,
                        };
                    },
                    else => null,
                };
                if (matches) |matches_value| return if (matches_value) .{ .reference = target } else .{ .choice = &.{} };
            }
        }
        return .{ .control = .{ .operator = definition.operator, .target = target, .controller = controller } };
    }

    fn enumerate(self: *Analyzer, id: Id, alternatives: *std.ArrayList(Id), visiting: *std.AutoHashMapUnmanaged(Id, void), source: Origin) Failure!void {
        if (visiting.contains(id)) return;
        try visiting.put(self.allocator, id, {});
        const node = self.nodes.items[id];
        switch (node.data) {
            .reference => |value| try self.enumerate(value, alternatives, visiting, source),
            .group, .sequence => |values| for (values) |value| try self.enumerate(value, alternatives, visiting, source),
            .entry => |entry| {
                if (entry.occurrence.max == 0) return;
                const value = self.dereference(entry.value) orelse entry.value;
                if (self.nodes.items[value].capability == .group) try self.enumerate(entry.value, alternatives, visiting, source) else try alternatives.append(self.allocator, entry.value);
            },
            else => return self.fail(.invalid_schema, source, "group enumeration requires a group-valued operand"),
        }
    }

    fn normalizeDerived(self: *Analyzer) Failure!void {
        const count = self.nodes.items.len;
        for (0..count) |index| {
            const node = self.nodes.items[index];
            switch (node.data) {
                .unwrap => |target| {
                    if (self.parameterDependent(target, 0)) continue;
                    const value = try self.unwrapValue(target, node.capability, node.origin, 0);
                    self.nodes.items[index].data = .{ .reference = value };
                    self.nodes.items[index].capability = self.nodes.items[value].capability;
                },
                .enumeration => |group| {
                    if (self.parameterDependent(group, 0)) continue;
                    var alternatives: std.ArrayList(Id) = .empty;
                    var visiting = std.AutoHashMapUnmanaged(Id, void){};
                    try self.enumerate(group, &alternatives, &visiting, node.origin);
                    self.nodes.items[index].data = .{ .choice = try alternatives.toOwnedSlice(self.allocator) };
                },
                .range_expression => |range| {
                    self.nodes.items[index].data = try self.normalizeRange(range.lower, range.upper, range.inclusive, node.origin);
                },
                .control => |control| {
                    for (controls.registry) |definition| {
                        if (definition.operator != control.operator) continue;
                        self.nodes.items[index].data = try self.normalizeControl(definition, control.target, control.controller, node.origin);
                        break;
                    }
                },
                .head => |head| {
                    if (head.number_type) |number_type| {
                        if (self.parameterDependent(number_type, 0)) continue;
                        if (!self.domain(number_type, .unsigned, 0)) return self.fail(.invalid_schema, node.origin, "representation head number type must contain only unsigned integers");
                        if (self.constant(number_type)) |number| {
                            if (number != .integer or number.integer < 0) return self.fail(.invalid_schema, node.origin, "representation head number must be an unsigned integer");
                            const value: u64 = @intCast(number.integer);
                            if (head.major == 7 and (value > 255 or value == 24 or (value >= 28 and value <= 31))) return self.fail(.invalid_schema, node.origin, "representation head denotes a reserved or invalid CBOR simple value");
                            self.nodes.items[index].data.head.number = value;
                            self.nodes.items[index].data.head.number_type = null;
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn requireCapability(self: *Analyzer, id: Id, capability: Capability, source: Origin) Failure!void {
        if (self.nodes.items[id].capability != capability) return self.fail(.invalid_schema, source, "resolved expression has an incompatible type/group capability");
    }

    fn resolveModelCapabilities(self: *Analyzer) Failure!void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.nodes.items) |*node| {
                if (node.data == .reference) {
                    const capability = self.nodes.items[node.data.reference].capability;
                    if (node.capability != capability) {
                        node.capability = capability;
                        changed = true;
                    }
                }
            }
        }
        for (self.nodes.items) |*node| {
            switch (node.data) {
                .entry => |*entry| {
                    entry.splice = self.nodes.items[entry.value].capability == .group;
                    if (entry.key) |key| {
                        try self.requireCapability(key.value, .type, node.origin);
                        try self.requireCapability(entry.value, .type, node.origin);
                    }
                },
                .choice => |values| for (values) |value| try self.requireCapability(value, .type, node.origin),
                .group, .sequence => |values| for (values) |value| try self.requireCapability(value, .group, node.origin),
                .array, .map => |group| try self.requireCapability(group, .group, node.origin),
                .control => |control| {
                    try self.requireCapability(control.target, .type, node.origin);
                    try self.requireCapability(control.controller, .type, node.origin);
                },
                .head => |head| {
                    if (head.number_type) |value| try self.requireCapability(value, .type, node.origin);
                    if (head.content) |value| try self.requireCapability(value, .type, node.origin);
                },
                else => {},
            }
        }
        for (self.instances.items) |instance| {
            if (instance.arguments.len == 0) self.rules.items[instance.rule].capability = self.nodes.items[instance.value].capability;
        }
    }

    fn nullable(self: *const Analyzer, id: Id, values: []const bool) bool {
        return switch (self.nodes.items[id].data) {
            .reference => |value| values[value],
            .group => |children| blk: {
                for (children) |child| if (values[child]) break :blk true;
                break :blk false;
            },
            .sequence => |children| blk: {
                for (children) |child| if (!values[child]) break :blk false;
                break :blk true;
            },
            .entry => |entry| entry.occurrence.min == 0 or (entry.splice and values[entry.value]),
            else => false,
        };
    }

    fn checkProgress(self: *Analyzer) Failure!void {
        const nullable_nodes = try self.allocator.alloc(bool, self.nodes.items.len);
        @memset(nullable_nodes, false);
        var changed = true;
        while (changed) {
            changed = false;
            for (nullable_nodes, 0..) |*value, index| {
                if (!value.* and self.nullable(@intCast(index), nullable_nodes)) {
                    value.* = true;
                    changed = true;
                }
            }
        }
        for (self.nodes.items) |node| {
            if (node.data == .entry) {
                const entry = node.data.entry;
                if (entry.occurrence.max == null and entry.splice and nullable_nodes[entry.value]) return self.fail(.invalid_schema, node.origin, "unbounded repetition of a nullable group cannot make progress");
            }
        }
        const colors = try self.allocator.alloc(u2, self.nodes.items.len);
        @memset(colors, 0);
        for (self.nodes.items, 0..) |_, index| try self.visitProgress(@intCast(index), colors, nullable_nodes, 0);
    }

    fn visitProgress(self: *Analyzer, id: Id, colors: []u2, nullable_nodes: []const bool, depth: usize) Failure!void {
        if (colors[id] == 2) return;
        const node = self.nodes.items[id];
        if (colors[id] == 1) return self.fail(.invalid_schema, node.origin, "recursive reference cycle can recur without consuming a data item");
        if (depth >= self.options.max_depth) return self.fail(.nesting_limit, node.origin, "recursion analysis nesting limit exceeded");
        colors[id] = 1;
        switch (node.data) {
            .reference => |value| try self.visitProgress(value, colors, nullable_nodes, depth + 1),
            .choice, .group => |values| for (values) |value| try self.visitProgress(value, colors, nullable_nodes, depth + 1),
            .sequence => |values| {
                for (values) |value| {
                    try self.visitProgress(value, colors, nullable_nodes, depth + 1);
                    if (!nullable_nodes[value]) break;
                }
            },
            .entry => |entry| if (entry.occurrence.max != 0) try self.visitProgress(entry.value, colors, nullable_nodes, depth + 1),
            .control => |control| {
                try self.visitProgress(control.target, colors, nullable_nodes, depth + 1);
                if (control.operator == .@"and" or control.operator == .within) try self.visitProgress(control.controller, colors, nullable_nodes, depth + 1);
            },
            else => {},
        }
        colors[id] = 2;
    }

    fn checkMaps(self: *Analyzer) Failure!void {
        const seen = try self.allocator.alloc(bool, self.nodes.items.len);
        for (self.nodes.items) |node| {
            if (node.data == .map) {
                @memset(seen, false);
                try self.mapGroup(node.data.map, seen, 0);
            }
        }
    }

    fn mapGroup(self: *Analyzer, id: Id, seen: []bool, depth: usize) Failure!void {
        if (seen[id]) return;
        seen[id] = true;
        const node = self.nodes.items[id];
        if (depth >= self.options.max_depth) return self.fail(.nesting_limit, node.origin, "map group analysis nesting limit exceeded");
        switch (node.data) {
            .reference => |value| try self.mapGroup(value, seen, depth + 1),
            .group, .sequence => |values| for (values) |value| try self.mapGroup(value, seen, depth + 1),
            .entry => |entry| {
                if (entry.splice) {
                    try self.mapGroup(entry.value, seen, depth + 1);
                } else if (entry.key == null) {
                    const resolved = self.dereference(entry.value) orelse return self.fail(.invalid_schema, node.origin, "map member has a cyclic value with no key");
                    const data = self.nodes.items[resolved].data;
                    if (data != .parameter and data != .unwrap) return self.fail(.invalid_schema, node.origin, "map member requires a key or a group with keyed members");
                }
            },
            else => return self.fail(.invalid_schema, node.origin, "map content must be a group"),
        }
    }
};

fn literalNumber(value: model.Literal) ?model.Number {
    return switch (value) {
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        else => null,
    };
}

/// f128 represents every i65 and f64 value exactly; comparisons never round a
/// wire integer through f64 (not even integers above 2^53).
fn numberOrder(left: model.Number, right: model.Number) std.math.Order {
    const a: f128 = switch (left) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
    };
    const b: f128 = switch (right) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
    };
    return std.math.order(a, b);
}

fn scalarEqual(left: model.Literal, right: model.Literal) bool {
    if (literalNumber(left)) |a| {
        if (literalNumber(right)) |b| return numberOrder(a, b) == .eq;
    }
    return literalEqual(left, right);
}

fn literalEqual(left: model.Literal, right: model.Literal) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .integer => |value| value == right.integer,
        .float => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.float)),
        .text => |value| std.mem.eql(u8, value, right.text),
        .bytes => |value| std.mem.eql(u8, value, right.bytes),
    };
}

test "semantic analysis accepts, rejects, and owns models exactly" {
    const Semantic = struct {
        fn analyzeText(allocator: std.mem.Allocator, text: []const u8, diagnostics: *diagnostic.Diagnostics, options: Options) !?model.Model {
            var tree = try parser.parse(allocator, .{ .name = "semantic test", .text = text }, diagnostics);
            defer tree.deinit();
            return analyze(allocator, &tree, diagnostics, options);
        }

        fn expectAccepted(text: []const u8) !void {
            var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
            defer diagnostics.deinit();
            var result = (try analyzeText(std.testing.allocator, text, &diagnostics, .{})).?;
            defer result.deinit();
            try std.testing.expect(!diagnostics.hasErrors());
        }

        fn expectRejected(text: []const u8) !void {
            var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
            defer diagnostics.deinit();
            try std.testing.expect((try analyzeText(std.testing.allocator, text, &diagnostics, .{})) == null);
            try std.testing.expect(diagnostics.hasErrors());
        }

        fn analyzeOwned(allocator: std.mem.Allocator) !void {
            var diagnostics = diagnostic.Diagnostics.init(allocator);
            defer diagnostics.deinit();
            var result = (try analyzeText(allocator, "root = {item: box<uint>, ? other: bytes}\nbox<t> = [t, \"owned\", h'0001']", &diagnostics, .{})).?;
            defer result.deinit();
        }
    };

    // Forward generic references retain an independent immutable model.
    {
        var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
        defer diagnostics.deinit();
        var result = (try Semantic.analyzeText(std.testing.allocator, "root = [box<uint>, box<uint>]\nbox<t> = [value: t]", &diagnostics, .{})).?;
        defer result.deinit();
        try std.testing.expect(!diagnostics.hasErrors());
        try std.testing.expectEqualStrings("root", result.rules[result.root_rule].name);
        var concrete: usize = 0;
        for (result.instantiations) |instance| if (!instance.template and std.mem.eql(u8, result.rules[instance.rule].name, "box")) {
            concrete += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), concrete);
    }

    // Explicit roots and complete prelude names are available.
    {
        var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
        defer diagnostics.deinit();
        var result = (try Semantic.analyzeText(std.testing.allocator, "members = (a: uint, b: text)\nmessage = [eb64legacy, b64legacy, float32-64, members]", &diagnostics, .{ .root = "message" })).?;
        defer result.deinit();
        try std.testing.expectEqualStrings("message", result.rules[result.root_rule].name);
    }

    // Constant comparisons preserve full wire integer precision.
    try std.testing.expectEqual(std.math.Order.lt, numberOrder(.{ .integer = 9007199254740992 }, .{ .integer = 9007199254740993 }));

    for ([_][]const u8{
        // Ordered augmentations and recursive containers.
        "root = node\nnode /= null\nnode = [node]\nnode /= uint",
        // Group enumeration, unwrap, cuts, and sockets.
        "root = [~pair, &labels, $extra]\npair = [uint, tstr]\nlabels = (a: 1, b: 2)\n$extra /= bool",
        // Constant comparison beyond f64 integer precision.
        "root = 9007199254740993 .gt 9007199254740992",
        // Generic numeric bounds and generic unwrap.
        "root = [bounded<1, 9>, body<[uint, tstr]>]\nbounded<a, b> = a .. b\nbody<t> = ~t",
        // Implicit choice definitions and matching repeated definitions.
        "root /= uint\nroot /= text\nsame = 1\nsame = 1",
        // Map group parameters and parameter-dependent unwrap.
        "root = [wrap<fields>, unpack<record>]\nfields = (a: uint, b: text)\nrecord = {fields}\nwrap<g> = {g}\nunpack<t> = {~t}",
        // Dynamic head constants and empty ranges.
        "root = [#7.<25>, #6.<tag>(uint), (3 ... 3) / null]\ntag = 24",
        // Guarded recursive unwrap resolves after rule construction.
        "root = [uint, ? tail]\ntail = ~root",
        // Enumerated constants in ranges and controls.
        "root = [lo .. hi, uint .lt hi]\nlo = &(one: 1)\nhi = &(nine: 9)",
    }) |text| try Semantic.expectAccepted(text);

    for ([_][]const u8{
        // Unknown controls, non-progressing recursion, and unresolved names.
        "root = uint .feature \"x\"",
        "root = alias\nalias = root",
        "root = {* uint}",
        "root = uint\nunused = missing",
        // Invalid controls, ranges, heads, and socket declarations.
        "root = uint .eq uint",
        "root = bstr .lt 2",
        "root = uint .regexp \"a\"",
        "root = 1 .. 2.0",
        "root = #0.28",
        "root = uint\n$socket = uint",
        "root = uint\nsame = 1\nsame = 2",
        "root = uint\nuint = text",
        // Control recursion must make progress.
        "root = any .and root",
    }) |text| try Semantic.expectRejected(text);

    // Allocation failures release both AST and model arenas.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Semantic.analyzeOwned, .{});
}
