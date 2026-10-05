const std = @import("std");
const compiler = @import("cddl_zig").compiler;

/// Stable diagnostic catalog. The value is the four decimal digits after `E`.
/// A code is never renumbered, reused, or given a different meaning.
pub const Code = enum(u16) {
    invalid_utf8 = 1,
    invalid_character = 101,
    unterminated_string = 102,
    invalid_escape = 103,
    invalid_number = 104,
    integer_overflow = 105,
    invalid_byte_string = 106,
    unexpected_token = 201,
    expected_token = 202,
    invalid_occurrence = 203,
    nesting_limit = 204,
    node_limit = 205,
    unknown_name = 301,
    duplicate_rule = 302,
    invalid_schema = 401,
    unsupported_extension = 501,
    unsupported_recursion = 502,
    unsupported_group_choice = 503,
    unsupported_group_occurrence = 504,
    unsupported_map_key = 505,
    unsupported_map_occurrence = 506,
    unsupported_control = 507,
    unsupported_head = 508,
    generation_overflow = 601,
    unresolved_template = 602,

    pub fn format(self: Code, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("E{d:0>4}", .{@intFromEnum(self)});
    }

    /// Accepts exactly `E` followed by four decimal digits.
    pub fn parse(text: []const u8) ParseResult {
        if (text.len != 5 or text[0] != 'E') return .malformed;
        var value: u16 = 0;
        for (text[1..]) |byte| {
            if (!std.ascii.isDigit(byte)) return .malformed;
            value = value * 10 + (byte - '0');
        }
        return if (std.enums.fromInt(Code, value)) |code| .{ .known = code } else .unknown;
    }

    pub fn fromDiagnostic(code: compiler.DiagnosticCode) Code {
        return switch (code) {
            inline else => |tag| @field(Code, @tagName(tag)),
        };
    }

    pub fn explanation(self: Code) []const u8 {
        return switch (self) {
            .invalid_utf8 => "Schema text must be valid UTF-8; a byte sequence is malformed or truncated.",
            .invalid_character => "A character is outside the RFC 9682 CDDL character set at this position, such as a control byte or a lone carriage return.",
            .unterminated_string => "A text or byte string literal has no closing quote.",
            .invalid_escape => "A text string contains an escape sequence that RFC 9682 does not define.",
            .invalid_number => "A numeric literal is malformed.",
            .integer_overflow => "An integer literal lies outside the CBOR integer range -2^64 through 2^64-1.",
            .invalid_byte_string => "A qualified byte string such as h'..' or b64'..' has invalid content for its encoding.",
            .unexpected_token => "A token cannot start or continue a CDDL construct at this position.",
            .expected_token => "A required token, such as '=' or a closing delimiter, is missing.",
            .invalid_occurrence => "An occurrence indicator has malformed or inverted bounds.",
            .nesting_limit => "The schema nests more deeply than the compiler's fixed nesting limit allows.",
            .node_limit => "The schema needs more syntax nodes, model nodes, or generic instantiations than the compiler allows.",
            .unknown_name => "A reference, generic argument, or selected --root names a rule or parameter that is not defined.",
            .duplicate_rule => "A rule has more than one '=' definition and the definitions differ.",
            .invalid_schema => "The schema violates an RFC 8610 structural or semantic rule; the message names the rule.",
            .unsupported_extension => "The schema uses a recognized CDDL extension that cddl-zig does not support, such as a module directive.",
            .unsupported_recursion => "A type refers back to itself; generated codecs do not support recursive types.",
            .unsupported_group_choice => "An array or map contains a group choice; generated codecs require a single group alternative there.",
            .unsupported_group_occurrence => "A group spliced into an array or map has an occurrence other than exactly once.",
            .unsupported_map_key => "A map member lacks a constant key, uses a type as its key, or repeats another member's key.",
            .unsupported_map_occurrence => "A map member may occur more than once; generated codecs support at most one occurrence.",
            .unsupported_control => "A control operator or controller form has no generated check, such as .regexp, .cborseq, or a non-constant comparison.",
            .unsupported_head => "A representation head carries a number type or content on a major type other than tags (6).",
            .generation_overflow => "Size arithmetic during code generation exceeded its integer domain.",
            .unresolved_template => "A generic template expression did not resolve to a concrete type during code generation.",
        };
    }
};

pub const ParseResult = union(enum) { known: Code, unknown, malformed };

pub const GenerationFailure = struct { code: Code, message: []const u8 };

/// Null for failures that are not properties of the schema.
pub fn fromGeneration(err: compiler.GenerateError) ?GenerationFailure {
    return switch (err) {
        error.UnsupportedRecursion => .{ .code = .unsupported_recursion, .message = "recursive type is not supported by generated codecs" },
        error.UnsupportedGroupChoice => .{ .code = .unsupported_group_choice, .message = "group choice inside an array or map is not supported by generated codecs" },
        error.UnsupportedGroupOccurrence => .{ .code = .unsupported_group_occurrence, .message = "spliced group must occur exactly once" },
        error.UnsupportedMapKey => .{ .code = .unsupported_map_key, .message = "map member key is not a distinct constant" },
        error.UnsupportedMapOccurrence => .{ .code = .unsupported_map_occurrence, .message = "map member may occur at most once" },
        error.UnsupportedControl => .{ .code = .unsupported_control, .message = "control operator is not supported by generated codecs" },
        error.UnsupportedHead => .{ .code = .unsupported_head, .message = "representation head number type or content is supported only for tags" },
        error.Overflow => .{ .code = .generation_overflow, .message = "code generation size arithmetic overflowed" },
        error.UnresolvedTemplate => .{ .code = .unresolved_template, .message = "generic template is unresolved during code generation" },
        error.OutOfMemory, error.InvalidModel, error.InvalidRuntimeImport, error.InvalidGeneratedSource => null,
    };
}

test "every compiler diagnostic maps to a distinct catalogued code" {
    var seen = std.EnumSet(Code).initEmpty();
    for (std.enums.values(compiler.DiagnosticCode)) |source_code| {
        const code = Code.fromDiagnostic(source_code);
        try std.testing.expect(!seen.contains(code));
        seen.insert(code);
        try std.testing.expectEqualStrings(@tagName(source_code), @tagName(code));
    }
}

test "codes format and parse as E plus four digits" {
    for (std.enums.values(Code)) |code| {
        var buffer: [5]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{f}", .{code});
        try std.testing.expectEqual(ParseResult{ .known = code }, Code.parse(text));
        try std.testing.expect(code.explanation().len != 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, code.explanation(), '\n') == null);
    }
    try std.testing.expectEqual(ParseResult{ .known = .unknown_name }, Code.parse("E0301"));
    try std.testing.expectEqual(ParseResult.unknown, Code.parse("E9999"));
    for ([_][]const u8{ "", "E301", "E03010", "e0301", "W0301", "E03a1", "E+301" }) |text| {
        try std.testing.expectEqual(ParseResult.malformed, Code.parse(text));
    }
}

test "schema-dependent generation failures have codes; internal ones do not" {
    try std.testing.expectEqual(Code.unsupported_map_key, fromGeneration(error.UnsupportedMapKey).?.code);
    try std.testing.expectEqual(Code.unsupported_recursion, fromGeneration(error.UnsupportedRecursion).?.code);
    try std.testing.expect(fromGeneration(error.InvalidModel) == null);
    try std.testing.expect(fromGeneration(error.InvalidGeneratedSource) == null);
    try std.testing.expect(fromGeneration(error.OutOfMemory) == null);
}
