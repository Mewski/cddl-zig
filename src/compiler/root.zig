//! RFC 8610 CDDL syntax with RFC 9682 Appendix A grammar updates.
//! Source bytes are borrowed; Ast owns all tree storage and decoded strings.
pub const source = @import("source.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const lexer = @import("lexer.zig");
pub const literals = @import("literals.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

pub const Source = source.Source;
pub const Span = source.Span;
pub const Diagnostic = diagnostics.Diagnostic;
pub const Diagnostics = diagnostics.Diagnostics;
pub const DiagnosticCode = diagnostics.Code;
pub const Ast = ast.Ast;
pub const Node = ast.Node;
pub const NodeId = ast.NodeId;
pub const Rule = ast.Rule;
pub const Literal = ast.Literal;
pub const Reference = ast.Reference;
pub const Occurrence = ast.Occurrence;
pub const Entry = ast.Entry;
pub const MemberKey = ast.MemberKey;
pub const GroupChoice = ast.GroupChoice;
pub const Head = ast.Head;
pub const ParseError = parser.ParseError;
pub const ParseOptions = parser.Options;
pub const parse = parser.parse;
pub const parseWithOptions = parser.parseWithOptions;

test {
    _ = source;
    _ = diagnostics;
    _ = lexer;
    _ = literals;
    _ = ast;
    _ = parser;
}
