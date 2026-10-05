const std = @import("std");
const syntax = @import("ast.zig");
const lex = @import("lexer.zig");
const literals = @import("literals.zig");
const diagnostic = @import("diagnostics.zig");
const Source = @import("source.zig").Source;
const Span = @import("source.zig").Span;
const NodeId = syntax.NodeId;
const Token = lex.Token;
const Kind = lex.Kind;
pub const ParseError = error{ OutOfMemory, InvalidSyntax };
pub const Options = struct { max_nesting: usize = 256 };

pub fn parse(allocator: std.mem.Allocator, source: Source, diagnostics: *diagnostic.Diagnostics) ParseError!syntax.Ast {
    return parseWithOptions(allocator, source, diagnostics, .{});
}

pub fn parseWithOptions(allocator: std.mem.Allocator, source: Source, diagnostics: *diagnostic.Diagnostics, options: Options) ParseError!syntax.Ast {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);
    const errors_before = diagnostics.total;
    var lexer = lex.Lexer.init(source, diagnostics);
    while (true) {
        const token = try lexer.next();
        try tokens.append(allocator, token);
        if (token.kind == .eof) break;
    }
    var parser: Parser = .{
        .allocator = arena.allocator(),
        .source = source,
        .diagnostics = diagnostics,
        .tokens = tokens.items,
        .options = options,
    };
    var rules: std.ArrayList(syntax.Rule) = .empty;
    var invalid = diagnostics.total != errors_before;
    while (parser.peek().kind != .eof) {
        const start = parser.index;
        const rule = parser.rule() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSyntax => {
                invalid = true;
                if (parser.index == start) parser.index += 1;
                while (parser.peek().kind != .eof and !parser.ruleStart()) parser.index += 1;
                continue;
            },
        };
        try rules.append(parser.allocator, rule);
    }
    if (invalid or diagnostics.total != errors_before) return error.InvalidSyntax;
    const owned_nodes = try parser.nodes.toOwnedSlice(parser.allocator);
    const owned_rules = try rules.toOwnedSlice(parser.allocator);
    return .{ .arena = arena, .source = source, .nodes = owned_nodes, .rules = owned_rules };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: Source,
    diagnostics: *diagnostic.Diagnostics,
    tokens: []const Token,
    options: Options,
    index: usize = 0,
    depth: usize = 0,
    nodes: std.ArrayList(syntax.Node) = .empty,

    fn peek(self: *const Parser) Token {
        return self.tokens[self.index];
    }
    fn previous(self: *const Parser) Token {
        return self.tokens[self.index - 1];
    }
    fn at(self: *const Parser, distance: usize) Kind {
        if (distance >= self.tokens.len - self.index) return .eof;
        return self.tokens[self.index + distance].kind;
    }
    fn take(self: *Parser) Token {
        const token = self.peek();
        if (token.kind != .eof) self.index += 1;
        return token;
    }
    fn accept(self: *Parser, kind: Kind) bool {
        if (self.peek().kind != kind) return false;
        _ = self.take();
        return true;
    }
    fn fail(self: *Parser, code: diagnostic.Code, source_span: Span, message: []const u8) ParseError {
        self.diagnostics.add(code, source_span, message) catch return error.OutOfMemory;
        return error.InvalidSyntax;
    }
    fn expect(self: *Parser, kind: Kind, message: []const u8) ParseError!Token {
        if (self.peek().kind != kind) return self.fail(.expected_token, self.peek().span, message);
        return self.take();
    }
    fn text(self: *const Parser, token: Token) []const u8 {
        return self.source.slice(token.span);
    }
    fn add(self: *Parser, source_span: Span, data: @FieldType(syntax.Node, "data")) ParseError!NodeId {
        if (self.nodes.items.len >= std.math.maxInt(NodeId)) return self.fail(.node_limit, source_span, "syntax tree exceeds the node index domain");
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .span = source_span, .data = data });
        return id;
    }
    fn span(self: *const Parser, id: NodeId) Span {
        return self.nodes.items[id].span;
    }

    fn ruleStart(self: *const Parser) bool {
        if (self.peek().kind != .identifier) return false;
        var look: usize = 1;
        if (self.at(look) == .less) {
            look += 1;
            if (self.at(look) != .identifier) return false;
            look += 1;
            while (self.at(look) == .comma) {
                look += 1;
                if (self.at(look) != .identifier) return false;
                look += 1;
            }
            if (self.at(look) != .greater) return false;
            look += 1;
        }
        return switch (self.at(look)) {
            .equal, .type_extend, .group_extend => true,
            else => false,
        };
    }

    fn rule(self: *Parser) ParseError!syntax.Rule {
        const name = try self.expect(.identifier, "expected a rule name");
        var parameters: std.ArrayList([]const u8) = .empty;
        if (self.peek().kind == .less and self.peek().span.start == name.span.end) {
            _ = self.take();
            while (true) {
                const parameter = try self.expect(.identifier, "expected a generic parameter name");
                try parameters.append(self.allocator, self.text(parameter));
                if (!self.accept(.comma)) break;
            }
            _ = try self.expect(.greater, "expected '>' after generic parameters");
        }
        const assignment = self.take();
        const operator: @FieldType(syntax.Rule, "assignment") = switch (assignment.kind) {
            .equal => .define,
            .type_extend => .type_extend,
            .group_extend => .group_extend,
            else => return self.fail(.expected_token, assignment.span, "expected '=', '/=', or '//=' after a rule name"),
        };
        const entry_id = try self.entry();
        const entry_data = self.nodes.items[entry_id].data.entry;
        const entry_span = self.span(entry_id);
        const plain = !entry_data.occurrence.explicit and entry_data.key == null;
        const type_capable = plain and self.typeCapable(entry_data.value);
        if (operator == .type_extend and !type_capable) return self.fail(.unexpected_token, self.span(entry_id), "type augmentation requires a type expression");
        const value = if (plain) entry_data.value else entry_id;
        if (plain) self.nodes.items.len -= 1;
        return .{
            .name = self.text(name),
            .parameters = try parameters.toOwnedSlice(self.allocator),
            .assignment = operator,
            .value = value,
            .rhs_kind = if (type_capable) .type_capable else .group_only,
            .span = .{ .start = name.span.start, .end = entry_span.end },
        };
    }

    fn typeCapable(self: *const Parser, id: NodeId) bool {
        return switch (self.nodes.items[id].data) {
            .parenthesized => |group_id| blk: {
                const choices = self.nodes.items[group_id].data.group;
                if (choices.len != 1) break :blk false;
                const choice = self.nodes.items[choices[0]].data.group_choice;
                if (choice.has_comma or choice.entries.len != 1) break :blk false;
                const item = self.nodes.items[choice.entries[0]].data.entry;
                break :blk !item.occurrence.explicit and item.key == null and self.typeCapable(item.value);
            },
            .group, .group_choice, .entry => false,
            else => true,
        };
    }

    fn typeExpression(self: *Parser) ParseError!NodeId {
        return self.typeTail(try self.type1());
    }

    fn typeTail(self: *Parser, first: NodeId) ParseError!NodeId {
        if (self.peek().kind != .slash) return first;
        if (!self.typeCapable(first)) return self.fail(.unexpected_token, self.span(first), "group expression cannot be a type alternative");
        var alternatives: std.ArrayList(NodeId) = .empty;
        try alternatives.append(self.allocator, first);
        while (self.accept(.slash)) {
            const next = try self.type1();
            if (!self.typeCapable(next)) return self.fail(.unexpected_token, self.span(next), "group expression cannot be a type alternative");
            try alternatives.append(self.allocator, next);
        }
        const range = Span.merge(self.span(first), self.span(alternatives.items[alternatives.items.len - 1]));
        return self.add(range, .{ .choice = try alternatives.toOwnedSlice(self.allocator) });
    }

    fn type1(self: *Parser) ParseError!NodeId {
        const first = try self.type2();
        const operator = self.peek();
        if (operator.kind != .range_inclusive and operator.kind != .range_exclusive and operator.kind != .dot) return first;
        if (!self.typeCapable(first)) return self.fail(.unexpected_token, self.span(first), "operator requires a type operand");
        _ = self.take();
        var control: ?Token = null;
        if (operator.kind == .dot) {
            control = try self.expect(.identifier, "expected a control operator name after '.'");
            if (control.?.span.start != operator.span.end) return self.fail(.unexpected_token, control.?.span, "control name must immediately follow '.'");
        }
        const last = try self.type2();
        if (!self.typeCapable(last)) return self.fail(.unexpected_token, self.span(last), "operator requires a type operand");
        const range = Span.merge(self.span(first), self.span(last));
        if (control) |name| return self.add(range, .{ .control = .{ .target = first, .controller = last, .name = self.text(name) } });
        return self.add(range, .{ .range = .{ .lower = first, .upper = last, .inclusive = operator.kind == .range_inclusive } });
    }

    fn reference(self: *Parser) ParseError!syntax.Reference {
        const name = try self.expect(.identifier, "expected a type or group name");
        var arguments: std.ArrayList(NodeId) = .empty;
        if (self.peek().kind == .less and self.peek().span.start == name.span.end) {
            _ = self.take();
            while (true) {
                const argument = try self.type1();
                if (!self.typeCapable(argument)) return self.fail(.unexpected_token, self.span(argument), "generic argument must be a type expression");
                try arguments.append(self.allocator, argument);
                if (!self.accept(.comma)) break;
            }
            _ = try self.expect(.greater, "expected '>' after generic arguments");
        }
        return .{ .name = self.text(name), .arguments = try arguments.toOwnedSlice(self.allocator) };
    }

    fn type2(self: *Parser) ParseError!NodeId {
        if (self.depth >= self.options.max_nesting) return self.fail(.nesting_limit, self.peek().span, "CDDL nesting limit exceeded");
        self.depth += 1;
        defer self.depth -= 1;
        const token = self.peek();
        switch (token.kind) {
            .number, .text, .bytes => {
                _ = self.take();
                const value = (if (token.kind == .number) literals.number(self.allocator, self.text(token)) else literals.string(self.allocator, self.text(token))) catch |err| {
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.IntegerOverflow => self.fail(.integer_overflow, token.span, "integer is outside the CBOR wire domain"),
                        error.InvalidNumber => self.fail(.invalid_number, token.span, "invalid or out-of-domain numeric literal"),
                        error.InvalidEscape => self.fail(.invalid_escape, token.span, "invalid string escape or Unicode scalar"),
                        error.InvalidByteString => self.fail(.invalid_byte_string, token.span, "invalid qualified byte string encoding"),
                    };
                };
                return self.add(token.span, .{ .literal = value });
            },
            .identifier => {
                const name = try self.reference();
                return self.add(Span.merge(token.span, self.previous().span), .{ .reference = name });
            },
            .tilde => {
                _ = self.take();
                const name = try self.reference();
                return self.add(Span.merge(token.span, self.previous().span), .{ .unwrap = name });
            },
            .ampersand => {
                _ = self.take();
                var value: NodeId = undefined;
                if (self.accept(.lparen)) {
                    value = try self.group(.rparen);
                    _ = try self.expect(.rparen, "expected ')' after group enumeration");
                } else {
                    const start = self.peek().span;
                    const name = try self.reference();
                    value = try self.add(Span.merge(start, self.previous().span), .{ .reference = name });
                }
                return self.add(Span.merge(token.span, self.previous().span), .{ .enumeration = value });
            },
            .lparen, .lbrace, .lbracket => {
                _ = self.take();
                const closing: Kind = switch (token.kind) {
                    .lparen => .rparen,
                    .lbrace => .rbrace,
                    else => .rbracket,
                };
                const contents = try self.group(closing);
                const close = try self.expect(closing, "expected matching closing delimiter");
                const range = Span.merge(token.span, close.span);
                return self.add(range, switch (token.kind) {
                    .lparen => .{ .parenthesized = contents },
                    .lbrace => .{ .map = contents },
                    else => .{ .array = contents },
                });
            },
            .hash => return self.head(),
            else => return self.fail(.unexpected_token, token.span, "expected a CDDL type, literal, or group expression"),
        }
    }

    fn unsigned(self: *Parser, token: Token) ParseError!u64 {
        return literals.unsigned(self.text(token)) catch |err| switch (err) {
            error.IntegerOverflow => self.fail(.integer_overflow, token.span, "unsigned integer exceeds u64"),
            else => self.fail(.invalid_number, token.span, "expected an unsigned integer"),
        };
    }

    fn head(self: *Parser) ParseError!NodeId {
        const hash = self.take();
        var result: syntax.Head = .{ .major = null };
        if (self.peek().kind != .number or self.peek().span.start != hash.span.end) return self.add(hash.span, .{ .head = result });
        const major_token = self.take();
        const major = try self.unsigned(major_token);
        if (major_token.span.end - major_token.span.start != 1 or major > 7) return self.fail(.invalid_number, major_token.span, "CBOR representation major type must be a single digit from 0 to 7");
        result.major = @intCast(major);
        if (self.peek().kind == .dot and self.peek().span.start == major_token.span.end and (self.at(1) == .number or self.at(1) == .less)) {
            const dot = self.take();
            if (self.peek().span.start != dot.span.end) return self.fail(.unexpected_token, self.peek().span, "representation head number must immediately follow '.'");
            if (self.accept(.less)) {
                if (major != 6 and major != 7) return self.fail(.unexpected_token, self.previous().span, "non-literal head numbers require major type 6 or 7");
                const less = self.previous();
                if (self.peek().span.start != less.span.end) return self.fail(.unexpected_token, self.peek().span, "head-number type must immediately follow '<'");
                const value = try self.typeExpression();
                if (!self.typeCapable(value)) return self.fail(.unexpected_token, self.span(value), "head number requires a type expression");
                const greater = try self.expect(.greater, "expected '>' after head-number type");
                if (greater.span.start != self.span(value).end) return self.fail(.unexpected_token, greater.span, "head-number type must immediately precede '>'");
                result.number_type = value;
            } else result.number = try self.unsigned(try self.expect(.number, "expected unsigned head number"));
        }
        if (major == 6 and (result.number_type != null or (self.peek().kind == .lparen and self.peek().span.start == self.previous().span.end))) {
            if (self.peek().kind != .lparen or self.peek().span.start != self.previous().span.end) return self.fail(.expected_token, self.peek().span, "tag head requires an immediately following parenthesized type");
            _ = self.take();
            const content = try self.typeExpression();
            if (!self.typeCapable(content)) return self.fail(.unexpected_token, self.span(content), "tag content must be a type expression");
            _ = try self.expect(.rparen, "expected ')' after tag content");
            result.content = content;
        }
        return self.add(Span.merge(hash.span, self.previous().span), .{ .head = result });
    }

    fn occurrence(self: *Parser) ParseError!syntax.Occurrence {
        if (self.accept(.question)) return .{ .min = 0, .max = 1, .explicit = true };
        if (self.accept(.plus)) return .{ .min = 1, .max = null, .explicit = true };
        var result: syntax.Occurrence = .{};
        const start = self.peek().span;
        if (self.peek().kind == .number and self.at(1) == .star and self.tokens[self.index + 1].span.start == start.end) {
            result.min = try self.unsigned(self.take());
        } else if (self.peek().kind == .star) result.min = 0 else return result;
        const star = try self.expect(.star, "expected '*' in occurrence");
        result.explicit = true;
        result.max = null;
        if (self.peek().kind == .number and self.peek().span.start == star.span.end) result.max = try self.unsigned(self.take());
        if (result.max) |maximum| {
            if (maximum < result.min) return self.fail(.invalid_occurrence, Span.merge(start, self.previous().span), "occurrence maximum is less than its minimum");
        }
        return result;
    }

    fn entry(self: *Parser) ParseError!NodeId {
        const start = self.peek().span;
        const occur = try self.occurrence();
        const first = try self.type1();
        var key: ?syntax.MemberKey = null;
        if (self.accept(.colon)) {
            const data = self.nodes.items[first].data;
            const kind: @FieldType(syntax.MemberKey, "kind") = switch (data) {
                .reference => |name| if (name.arguments.len == 0) .bareword else return self.fail(.unexpected_token, self.span(first), "colon label cannot have generic arguments"),
                .literal => .literal,
                else => return self.fail(.unexpected_token, self.span(first), "colon key must be a bareword or literal"),
            };
            key = .{ .value = first, .kind = kind, .cut = true };
        } else if (self.peek().kind == .cut or self.peek().kind == .arrow) {
            if (!self.typeCapable(first)) return self.fail(.unexpected_token, self.span(first), "map key must be a type expression");
            const cut = self.accept(.cut);
            _ = try self.expect(.arrow, "expected '=>' after member key");
            key = .{ .value = first, .kind = .type, .cut = cut };
        }
        const value = if (key != null) try self.typeExpression() else try self.typeTail(first);
        if (key != null and !self.typeCapable(value)) return self.fail(.unexpected_token, self.span(value), "keyed member requires a type value");
        return self.add(Span.merge(start, self.span(value)), .{ .entry = .{ .occurrence = occur, .key = key, .value = value } });
    }

    fn group(self: *Parser, closing: Kind) ParseError!NodeId {
        const start = self.peek().span.start;
        var choices: std.ArrayList(NodeId) = .empty;
        while (true) {
            const choice_start = self.peek().span.start;
            var entries: std.ArrayList(NodeId) = .empty;
            var has_comma = false;
            var trailing_comma = false;
            while (self.peek().kind != closing and self.peek().kind != .group_slash and self.peek().kind != .eof) {
                try entries.append(self.allocator, try self.entry());
                trailing_comma = self.accept(.comma);
                has_comma = has_comma or trailing_comma;
            }
            const end = if (entries.items.len == 0) choice_start else self.previous().span.end;
            const choice_id = try self.add(.{ .start = choice_start, .end = end }, .{ .group_choice = .{
                .entries = try entries.toOwnedSlice(self.allocator),
                .has_comma = has_comma,
                .trailing_comma = trailing_comma,
            } });
            try choices.append(self.allocator, choice_id);
            if (!self.accept(.group_slash)) break;
        }
        const end = if (self.index == 0) start else @max(start, self.previous().span.end);
        return self.add(.{ .start = start, .end = end }, .{ .group = try choices.toOwnedSlice(self.allocator) });
    }
};

test "empty model and all core syntax shapes" {
    const allocator = std.testing.allocator;
    var diagnostics = diagnostic.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    var empty = try parse(allocator, .{ .name = "empty", .text = "" }, &diagnostics);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.rules.len);
    const text =
        "pair<t> = [first: t, ? second: t]\n" ++
        "socket = { * tstr ^ => uint, ? name: tstr .size (1..64) }\n" ++
        "tag = #6.<42 / 43>(pair<uint>)\n" ++
        "simple = #7.<20..23>\n" ++
        "raw = #2.4 / # / -18446744073709551616 / 0x1.fp+2\n" ++
        "g = (a: uint, // b: tstr,)\n" ++
        "e = &(one: 1, two: 2) / &g\n" ++
        "u = ~pair<uint>\n" ++
        "$extension /= bytes\n" ++
        "$$entries //= (0*2 uint)\n";
    var ast = try parse(allocator, .{ .name = "core", .text = text }, &diagnostics);
    defer ast.deinit();
    try std.testing.expectEqual(@as(usize, 10), ast.rules.len);
    try std.testing.expectEqual(.group_only, ast.rules[5].rhs_kind);
    try std.testing.expect(!diagnostics.hasErrors());
}

test "parentheses preserve group and comma ambiguity" {
    var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var ast = try parse(std.testing.allocator, .{ .name = "test", .text = "a = (b)\nc = (b,)\nd = ()" }, &diagnostics);
    defer ast.deinit();
    try std.testing.expectEqual(.type_capable, ast.rules[0].rhs_kind);
    try std.testing.expectEqual(.group_only, ast.rules[1].rhs_kind);
    try std.testing.expectEqual(.group_only, ast.rules[2].rhs_kind);
}

test "malformed input recovers with bounded source-aware diagnostics" {
    var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    diagnostics.limit = 2;
    const text = "a = [,,,]\nb = #9\nc = 3*2 uint\nd = \"\\q\"";
    try std.testing.expectError(error.InvalidSyntax, parse(std.testing.allocator, .{ .name = "bad", .text = text }, &diagnostics));
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.items.len);
    try std.testing.expect(diagnostics.total >= 4);
    for (diagnostics.items.items) |item| {
        try std.testing.expect(item.span.start <= item.span.end);
        try std.testing.expect(item.span.end <= text.len);
    }
}

test "nesting limit is explicit" {
    var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.InvalidSyntax, parseWithOptions(std.testing.allocator, .{ .name = "deep", .text = "a = [[[[uint]]]]" }, &diagnostics, .{ .max_nesting = 2 }));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var diagnostics = diagnostic.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    var ast = try parse(allocator, .{ .name = "allocation", .text = "x<t> = [a: t, ? b: h'4342', 0b11.5e2, (1 // 2)]" }, &diagnostics);
    defer ast.deinit();
}

test "every allocation failure releases partial syntax trees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "representation heads retain bare major six and adjacent controls" {
    var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var ast = try parse(std.testing.allocator, .{ .name = "heads", .text = "a = #6 / #6.24 / #6(uint) / #7.eq 20" }, &diagnostics);
    defer ast.deinit();
    const alternatives = ast.node(ast.rules[0].value).data.choice;
    try std.testing.expect(ast.node(alternatives[0]).data.head.content == null);
    try std.testing.expect(ast.node(alternatives[1]).data.head.content == null);
    try std.testing.expect(ast.node(alternatives[2]).data.head.content != null);
    try std.testing.expectEqualStrings("eq", ast.node(alternatives[3]).data.control.name);
}

test "all truncated prefixes terminate with in-bounds diagnostics" {
    const text = "shape<t> = { ? label: [t, h'43', #6.<42>(t)], * tstr ^ => uint }";
    for (0..text.len + 1) |end| {
        var diagnostics = diagnostic.Diagnostics.init(std.testing.allocator);
        defer diagnostics.deinit();
        if (parse(std.testing.allocator, .{ .name = "prefix", .text = text[0..end] }, &diagnostics)) |result| {
            var ast = result;
            ast.deinit();
        } else |err| {
            if (err != error.InvalidSyntax) return err;
        }
        for (diagnostics.items.items) |item| {
            try std.testing.expect(item.span.start <= item.span.end);
            try std.testing.expect(item.span.end <= end);
        }
    }
}
