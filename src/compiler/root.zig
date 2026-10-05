//! RFC 8610 CDDL parsing and semantics with RFC 9682 grammar updates.
//! Ast borrows source bytes. The immutable normalized Model owns its storage.
pub const source = @import("source.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const lexer = @import("lexer.zig");
pub const literals = @import("literals.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const model = @import("model.zig");
pub const semantic = @import("semantic.zig");
pub const prelude = @import("prelude.zig");
pub const controls = @import("controls.zig");
pub const names = @import("names.zig");
pub const plan = @import("plan.zig");
pub const generation = @import("generate.zig");

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
pub const Model = model.Model;
pub const AnalyzeError = semantic.AnalyzeError;
pub const AnalyzeOptions = semantic.Options;
pub const analyze = semantic.analyze;
pub const GenerateError = generation.Error;
pub const GenerateOptions = generation.Options;
pub const generate = generation.generate;

test {
    _ = source;
    _ = diagnostics;
    _ = lexer;
    _ = literals;
    _ = ast;
    _ = parser;
    _ = model;
    _ = semantic;
    _ = prelude;
    _ = controls;
    _ = names;
    _ = plan;
    _ = generation;
}
