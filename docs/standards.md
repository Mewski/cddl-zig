# Standards support

This document states the implemented boundary. `Supported` means `check` and
`generate` preserve the CDDL value set on encode and decode. `Unsupported` means
a stable error diagnostic and no output. Unsupported constructs are never
replaced with `any`, dropped, or treated as annotations.

## Baseline

| Document | Use |
|---|---|
| RFC 8610 | CDDL core semantics, control operators, and Appendix D prelude |
| RFC 9682 | CDDL grammar used by the lexer and parser |
| RFC 8949 | CBOR validity, data-model equality, and deterministic encoding |

RFC 9165 and RFC 9741 control operators are not implemented. An unknown control
operator is an unsupported-extension error. CDDL module directives (`;# import`
and `;# include`) are detected at column 1 and rejected rather than consumed as
ordinary comments.

## Source language

| Construct | Status | Notes |
|---|---|---|
| UTF-8 source, SP/LF/CRLF whitespace, comments | Supported | Invalid UTF-8, bare CR, TAB, and forbidden controls are diagnosed. |
| Identifiers and forward references | Supported | Names are case-sensitive. Undefined ordinary names are errors. |
| Decimal, hexadecimal, and binary integers | Supported | Exact domain is `-2^64...2^64-1`, represented internally as `i65`. |
| Decimal and hexadecimal floats | Supported | Stored as binary64 with exact bits retained. |
| Text, byte, `h'...'`, and `b64'...'` literals | Supported | Escape and encoding errors are diagnosed. |
| Rules, `/=`, `//=`, sockets, and plugs | Supported in semantic analysis | Generation remains subject to the structural restrictions below. |
| Appendix D prelude | Supported | Conflicting redefinitions are duplicate-rule errors. |
| Type choices `/` | Supported | Alternatives retain source order. |
| Numeric ranges `..` and `...` | Supported | Descending and empty ranges denote an empty type. |
| Representation types and tags | Supported with restrictions | Static heads are supported. A dynamic selector is supported only for major type 6 tags. |
| Unwrap `~` and group-to-choice `&` | Supported when normalization produces a supported graph | Unresolved generic/template operations are rejected. |
| Generics | Supported by concrete monomorphization | Generic declarations are not exported as Zig generic APIs. |
| Recursive type graphs | Unsupported in generation | Reported as `E0502`; no recursive Zig representation is guessed. |
| Empty or comment-only schema | Unsupported semantically | A generated module requires a root rule. |
| Multiple source files per CLI invocation | Unsupported by the CLI | One file or stdin keeps every span tied to one exact source. |

## Groups, arrays, and maps

| Construct | Status | Notes |
|---|---|---|
| Fixed array groups | Supported | Generated as structs in item order. |
| Optional array entries | Supported | Generated as optional fields. |
| Repeated array entries | Supported | Generated as slices; min/max are checked. |
| Nested group splicing | Supported for exactly-one occurrence | A repeated group splice is `E0504`. |
| Group alternatives `//` | Unsupported in generation | Reported as `E0503`. |
| Maps with unique constant keys | Supported | Text, numeric, and simple-value keys are matched exactly; wire order is irrelevant. |
| Optional map entries | Supported | A literal key can occur at most once. |
| Repeated or unbounded map-key occurrences | Unsupported | Reported as `E0506`. |
| Type/dynamic map keys | Unsupported | Reported as `E0505`. |
| Duplicate schema map keys | Unsupported | Reported as `E0505`; duplicate wire keys are runtime errors. |
| Cuts | Parsed and normalized | They do not change behavior for the supported unique-constant-key map subset. |

Group alternatives and repeated group splices are accepted by the parser and
semantic model so they receive precise source diagnostics at codec planning.
`check` runs codec planning and therefore rejects them exactly as `generate`
does.

## RFC 8610 controls

| Operator | Status | Generation restriction |
|---|---|---|
| `.size` | Supported | Controller must reduce to a finite unsigned singleton, range, representation type, or choice for which an upper bound is computable. Text and bytes count bytes; unsigned integers are constrained by value. |
| `.bits` | Supported | Target must be `uint` or `bstr`; every set-bit position must match the controller. |
| `.cbor` | Supported | Target bytes must contain exactly one valid CBOR item matching the controller. |
| `.and`, `.within` | Supported | Both target and controller are checked. No static subset proof is claimed for `.within`. |
| `.lt`, `.le`, `.gt`, `.ge` | Supported | Controller must reduce to one numeric literal. |
| `.eq`, `.ne` | Supported | Controller must reduce to one scalar literal or simple value. |
| `.default` | Supported as a constraint | The target mapping is retained; no implicit value is inserted into the Zig struct. |
| `.regexp` | Unsupported | Reported as `E0507`. |
| `.cborseq` | Unsupported | Reported as `E0507`. |
| Any other operator | Unsupported | Reported by semantic analysis as `E0501`. |

Numeric comparison uses an exact `f128` comparison domain, which represents every
`i65` and binary64 value without first rounding an integer through binary64.
Literal identity retains binary64 bits where CDDL requires kind-sensitive
identity; top-level numeric `.eq`/`.ne` compares numeric values.

## CBOR runtime

| Behavior | Status |
|---|---|
| Definite and indefinite strings, arrays, and maps | Supported |
| Unsigned and negative integers through the full CBOR wire domain | Supported as `i65` |
| Tags, simple values, booleans, null, undefined, and binary16/32/64 floats | Supported |
| UTF-8 validation and structural well-formedness | Supported |
| Duplicate map-key rejection using RFC 8949 data-model equality | Supported |
| Valid non-preferred input | Accepted by default |
| Core deterministic input validation | Optional with `DecodeOptions.require_deterministic` |
| Core deterministic output | Always used by the encoder |
| Resource limits | Depth, items, string bytes, cumulative allocated bytes, and work |

The cumulative allocation limit is charged for every successful allocation in
one decode. Freeing or shrinking does not refund it, which keeps the limit sound
when the backing allocator is an arena.

## Generated API boundary

Every non-generic named type rule gets a PascalCase type and a companion
`TypeNameCodec`. The codec exposes `validate`, `encode`, and `decode`. A decoded
value owns an arena and must be released with `Decoded.deinit`.

Planning failures are stable schema diagnostics:

| Code | Meaning |
|---|---|
| `E0502` | recursive graph |
| `E0503` | group alternative |
| `E0504` | repeated group splice |
| `E0505` | dynamic or duplicate map key |
| `E0506` | repeated map-key occurrence |
| `E0507` | unsupported control shape/operator |
| `E0508` | unsupported representation-head shape |
| `E0602` | unresolved generic/template operation |

The complete diagnostic catalog is available through `cddl-zig explain CODE`.
