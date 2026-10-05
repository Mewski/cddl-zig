# Standards support

This document is the support boundary of `cddl-zig`. Every row is a commitment: a
**Supported** construct has exact semantics in both the decoder and the encoder, and
an **Unsupported** construct makes `check` and `generate` fail with an error-severity
diagnostic at the construct's span. Nothing outside this document is accepted
silently.

Status vocabulary:

| Status | Observable behavior |
|---|---|
| Supported | `check` succeeds; `generate` emits types and codecs that accept exactly the CDDL value set. |
| Supported (folded) | The construct is evaluated at generation time into a constant. The result is matched exactly. |
| Supported (annotation) | Matching is unchanged; the construct is preserved as generated metadata. |
| Unsupported | Error diagnostic in the unsupported class (`E05xx`) at the construct's span. Nothing is generated for any input set that contains it. |
| Not CDDL | The input is not valid under the normative grammar. A syntax diagnostic is emitted. |

A construct is never downgraded to `any`, never left unvalidated, and never
approximated by a wider or narrower set. The only user-controlled exception is
`--opaque <rule>` (see [mapping.md](mapping.md#opaque-rules)). It always emits a
warning.

## Normative baseline

| Document | Role |
|---|---|
| RFC 8610 | CDDL core: semantics, prelude (Appendix D), PEG matching (Appendices A and C), and control operators of Section 3.8. |
| RFC 9682 | Replaces the grammar. Its Appendix A is the only grammar `cddl-zig` parses; RFC 8610 Appendix B is not used. |
| RFC 9165 | Control operators `.plus`, `.cat`, `.det`, `.abnf`, `.abnfb`, `.feature`, decided operator by operator below. |
| RFC 9741 | Control operators for text conversion and processing, decided operator by operator below. |
| RFC 8949 | CBOR well-formedness, validity, map-key equivalence, preferred serialization, and core deterministic encoding. |
| RFC 4648, RFC 9285 | Alphabets and strictness rules referenced by the RFC 9741 base-N operators. |
| RFC 8259 | JSON text syntax for `.json`. |
| XML Schema Part 2, Appendix F | Regular-expression language for `.regexp`, as RFC 8610 Section 3.8.3 requires. |

Out of scope, each with defined behavior:

| Item | Behavior |
|---|---|
| CDDL module directives (`;# import`, `;# include`, from draft-ietf-cbor-cddl-modules) | A comment that starts at column 1 with `;#`, one or more spaces, then `import` or `include` followed by a space is reported as Unsupported. Other comments, including `;####` banners, stay comments. |
| Extended Diagnostic Notation (RFC 8610 Appendix G and its successors) | Not CDDL. EDN-only forms such as `<<...>>`, adjacent string concatenation, `0o` numbers, `/` comments, and qualifiers other than `h` and `b64` get syntax diagnostics. |
| JSON use of CDDL (RFC 8610 Appendix E) | Not applicable. Generated codecs read and write CBOR only. The one JSON-related feature in scope is the `.json` control operator. |
| Control operators registered by any other document (for example RFC 9090), or not registered at all | Unsupported. The message names the operator and says it is outside the supported set. |

## RFC 8610 core with the RFC 9682 grammar

### Source text and lexical rules

| Construct | Reference | Status | Observable behavior |
|---|---|---|---|
| Source encoding | RFC 9682 App. A (`NONASCII`, `PCHAR`) | Supported | Input must be UTF-8. An invalid sequence is an error at the first bad byte. |
| Whitespace | `S`, `WS`, `NL` | Supported | Only SP, LF, CRLF, and comments are whitespace. A TAB, a bare CR, and any other control character are invalid characters. |
| Comments | `COMMENT`, `PCHAR` | Supported | A comment runs from `;` to LF. It must not contain C0 controls or U+007F through U+009F. A comment that ends at end of file without a line feed is an error. |
| Identifiers | `id`, `EALPHA` | Supported | ASCII only and case-sensitive. `-` and `.` are allowed only between name characters, so `min..max` is one name and `min .. max` is a range. |
| Unsigned integers | `uint` | Supported | Decimal, `0x` hexadecimal, and `0b` binary. A literal outside `0..2^64-1` is an error. |
| Integers | `int` | Supported | A negative literal must be at least `-2^64`. Literals are never rounded. |
| Floats | `number`, `hexfloat` | Supported | Any number with a fraction or an exponent is a float, so `1e3` is a float and never matches the integer `1000`. Hex floats (`0x1.8p0`) are exact. A literal that overflows binary64 is an error. |
| Text literals | `text`, `SCHAR`, `SESC` | Supported | The escapes are `\" \/ \\ \b \f \n \r \t`, `\uXXXX` for a non-surrogate, a surrogate pair `\uD8xx\uDCxx`, and `\u{hex}`. `\u{}` takes leading zeros and any scalar value up to U+10FFFF that is not a surrogate. A lone or reversed surrogate, any other escape letter, and a raw LF, DEL, C1, or surrogate are errors. |
| Byte literals given as text | `bytes`, `BCHAR` | Supported | Same escapes as text, plus `\'`. LF and CRLF stay in the value exactly as written. |
| `h'...'` | RFC 9682 Sec. 2.1.3, App. B.2 | Supported | Escapes are decoded first (outer layer). Then whitespace and `;` comments are removed and hex digits in either case are decoded. An odd number of digits is an error. |
| `b64'...'` | RFC 8610 Sec. 3.1 | Supported | Same two layers. The decoder accepts the classic and the URL-safe alphabets, with or without padding. Bad characters, impossible lengths, and misplaced padding are errors. |
| Empty data model | RFC 9682 Sec. 3.1 | Supported | An empty or comment-only file parses. The rule that at least one rule must exist applies after all input files are combined. Breaking it is a semantic error for both `check` and `generate`. |

### Rules, names, and root

| Construct | Reference | Status | Observable behavior |
|---|---|---|---|
| Type and group rules `=` | RFC 8610 Sec. 3 | Supported | Forward references and recursive references resolve. A second `=` definition of a name is accepted only if its token sequence is identical, ignoring whitespace and comments. Otherwise it is a duplicate-rule error that points at both definitions. |
| Prelude | RFC 8610 App. D | Supported | Every Appendix D name is predefined. The prelude follows user rules, so it never supplies the root. Redefining a prelude name with a different expression is a duplicate-rule error. |
| Root | RFC 8610 Sec. 2.2.4 | Supported | The root is the first rule in input order, so empty files are skipped. If that rule is a group rule or a generic rule, `check` and `generate` report an error unless `--root` names a non-generic type rule. `--root` naming a group rule, a generic rule, or an undefined name is an error. |
| Multiple input files | (tool behavior) | Supported | Files are combined in command-line order into one namespace. A rule cannot span files. |
| Type/group sort | RFC 8610 Sec. 2.1, 3 | Supported | Whether a rule is a type or a group is decided from its definition and its uses, after parsing. Using a group where a type is required is an error that shows both the definition and the use. |
| Undefined names | RFC 8610 Sec. 3.9 | Supported | An undefined name that starts with `$` is an empty type choice. One that starts with `$$` is an empty group choice. Any other undefined name is an error. It is never treated as `any`. |

### Types

| Construct | Reference | Status | Observable behavior |
|---|---|---|---|
| Literal values | RFC 8610 Sec. 2.2.1 | Supported | An integer literal matches only integer data items and a float literal matches only float data items. Text and byte literals match byte for byte. A float literal matches only its exact value, so `0.0` does not match `-0.0`. |
| Type choice `/` | RFC 8610 Sec. 2.2.2, App. A | Supported | Ordered. On decode, the first alternative that matches is selected. |
| Augmentation `/=`, `//=` | RFC 8610 Sec. 3.9 | Supported | Alternatives are appended in source order across files. Either form may be the first definition. Mixing the type form and the group form for one name is an error. |
| Ranges `..` and `...` | RFC 8610 Sec. 2.2.2.1 | Supported | Both endpoints must be singleton numbers of the same kind (integer or float). `...` excludes the upper endpoint. A descending or empty range is a legal empty type. Ranges are evaluated exactly over `-2^64..2^64-1` and binary64. |
| Representation types `#`, `#0`..`#7`, `#n.ai` | RFC 8610 Sec. 2.2.3; RFC 9682 Sec. 3.2 | Supported | These denote value sets, not wire forms. For example, `#7.25` accepts any float whose value is exact in binary16, whatever width it arrived in. For major types 0 through 5, additional information 28 to 30 is an error, and so are `#0.31` and `#1.31`. Additional information 31 (indefinite length) on major types 2 through 5 means the whole major type. `#8` and `#9` match the grammar's `DIGIT` but are semantic errors. See [mapping.md](mapping.md#representation-types). |
| Tags `#6.n(T)` and `#6(T)` | RFC 8610 Sec. 3.6 | Supported | The tag number is checked exactly and nested tags stay nested. Tag 55799 is never stripped unless the schema says it is there. |
| Non-literal tag numbers `#6.<T>(U)` | RFC 9682 Sec. 3.2 | Supported | `T` is a type over unsigned integers. The tag number is stored in the value and checked on encode and decode. |
| Simple values `#7.n` and `#7.<T>` | RFC 9682 Sec. 3.2 | Supported | 0 to 23 and 32 to 255 are simple values (20 to 23 are `false`, `true`, `null`, and `undefined`). 24 means the simple values 32 to 255. 25 to 27 mean the float16/32/64 value sets. 28 to 31 do not denote data items and are errors. |
| Unwrap `~` | RFC 8610 Sec. 3.7 | Supported | Removes one layer: an array or map gives its group, and a tag gives its content type. Unwrapping anything else is an error. |
| Group-to-choice `&` | RFC 8610 Sec. 2.2.2.2 | Supported | Builds a choice of the entry value types in member order. The member names are only names; they are not wire values. |
| Generics | RFC 8610 Sec. 3.10 | Supported | Arguments may be types, literals, ranges, or groups. Every concrete use is monomorphized; generic rules with no concrete use generate nothing. A wrong arity or a duplicate parameter is an error. Instantiation that keeps growing hits a limit and gets a diagnostic with the instantiation chain. |
| Operator precedence | RFC 8610 Sec. 3.11; RFC 9682 `type1` | Supported | A range or control operator takes `type2` operands, so `a .size 2 .le 4` is a syntax error and `(a .size 2) .le 4` is valid. |

### Groups, arrays, and maps

| Construct | Reference | Status | Observable behavior |
|---|---|---|---|
| Groups and entries | RFC 8610 Sec. 2.1 | Supported | Named, inline, and nested groups splice into the containing array or map. An empty group is legal. |
| Occurrence `?`, `*`, `+`, `n*m` | RFC 8610 Sec. 3.2 | Supported | Normalized to bounds. `n*m` with `n > m` is an error. Bounds are checked on encode and decode. |
| PEG matching | RFC 8610 App. A, App. C | Supported | Occurrences are greedy and never give back items. Group choices `//` are ordered. Once an alternative succeeds it is not retried because a later sibling fails. So `[? uint, uint]` rejects `[1]`, and `[* uint, uint]` matches no array. |
| Arrays | RFC 8610 Sec. 3.4 | Supported | Order and arity are exact. Member names are annotations only. |
| Maps | RFC 8610 Sec. 3.5 | Supported | Wire order does not matter. A map with any pair that no entry consumes is rejected. Duplicate keys are rejected by RFC 8949 Section 5.6.1 equivalence. |
| Member keys `bareword:`, `value:`, `type =>`, `type ^ =>` | RFC 8610 Sec. 3.5.1, 3.5.4 | Supported | `k:` is the text key `"k"`. `k =>` uses the type named `k`. `:` and `^ =>` are cuts: once the key matches, a value mismatch fails the whole map. |
| Map entry selection | RFC 8610 Sec. 3.5.3 | Supported | Entries are tried in group order. Each entry consumes the not-yet-consumed pairs it matches, in ascending order of the keys' deterministic encodings, up to its maximum. Earlier entries do not give pairs back. The result is the same for every wire order. |
| Repeated literal keys | RFC 8610 Sec. 3.2 | Supported | A literal key appears at most once, whatever its occurrence says. `*` and `?` therefore both mean 0..1, and a minimum above 1 makes the entry unsatisfiable (warning). |
| Sockets and plugs `$`, `$$` | RFC 8610 Sec. 3.9 | Supported | Plugs are appended in source order. An unplugged socket is an empty choice. A plug defined with a plain `=` is a duplicate-rule error if the socket already has a definition. |

### RFC 8610 control operators

| Operator | Status | Observable behavior |
|---|---|---|
| `.size` | Supported | On `bstr` or `tstr` it counts bytes, not characters. On `uint`, `.size n` means `0 <= x < 256^n`; it limits the value, not the encoded width. The controller may be any unsigned integer type. Any other target is an operand error. |
| `.bits` | Supported | The target is `uint` or `bstr`. For a byte string, bit `n` is `(b[n >> 3] >> (n & 7)) & 1`. Every set bit must be in the controller's set. |
| `.regexp` | Supported, except the constructs listed in the next row | The target is text and the controller is a singleton text value. The language is XSD Appendix F. The match is anchored implicitly over Unicode scalar values, and `^` and `$` are ordinary characters. Supported syntax: branches, groups, quantifiers including `{n,m}`, `.` (any character except LF and CR), character classes with ranges, negation and subtraction (`[a-z-[aeiou]]`), single-character escapes, and `\s` / `\S` (SP, TAB, LF, CR). Matching is case-sensitive and runs in linear time with no backtracking. The program size counts against compiler limits and the matching steps count against `Limits.max_work`. Invalid pattern syntax is an error at the offending pattern position. |
| `.regexp` constructs that need Unicode Character Database tables | Unsupported | `\p{..}`, `\P{..}`, `\d`, `\D`, `\w`, `\W`, `\i`, `\I`, `\c`, and `\C` are rejected at their position in the pattern (decoded offsets are mapped back to source spans). This is a known gap in RFC 8610 core conformance: the project ships no Unicode property data. |
| `.cbor` | Supported | The target is `bstr`. The bytes must hold exactly one well-formed, valid data item that matches the controller, with nothing after it. The nested item shares the outer depth and work limits. The byte string is stored unchanged. |
| `.cborseq` | Supported | The target is `bstr`. The bytes must hold zero or more complete data items that, taken as an array, match the controller. |
| `.and` | Supported | Intersection: both sides must match. |
| `.within` | Supported | Intersection with the same matching as `.and`. Subset intent is not proved. When generation finds a value that matches the target but not the controller, it reports a warning. |
| `.lt`, `.le`, `.gt`, `.ge` | Supported | Numeric target with a singleton numeric controller. Integer and float values are compared exactly, never by converting the integer to binary64. NaN fails every comparison. |
| `.eq`, `.ne` | Supported | Equality follows RFC 8610 Section 3.8.6. At the top level, numbers compare by numeric value. Inside arrays, maps, and tags they must also be the same kind (integer or float). Maps compare without regard to order. |
| `.default` | Supported | Adds the implied `.ne`: sending the default value is rejected on encode and decode. An absent member stays absent and the default is published as metadata (see [mapping.md](mapping.md#default)). Outside an optional context, `.default` gets a warning. |

## RFC 9165 control operators

| Operator | Status | Observable behavior |
|---|---|---|
| `.plus` | Supported (folded) | Both operands must be singleton numbers. The exact sum is converted to the target's kind: rounded to nearest-even binary64 for a float target, floored for an integer target. An integer result outside `-2^64..2^64-1` and an infinite float result are errors. A non-singleton operand is Unsupported. |
| `.cat` | Supported (folded) | Both operands must be singleton strings. Their bytes are concatenated and the result has the target's kind. A text result that is not valid UTF-8 is an error. A non-singleton operand is Unsupported. |
| `.det` | Supported (folded) | Like `.cat`, but each operand is dedented first. Lines end at LF. A blank line has only SP characters (and an optional CR before the LF). The common prefix of U+0020 across non-blank lines is removed; on blank lines all leading spaces are removed. TAB is not indentation. |
| `.feature` | Supported (annotation) | Matching is the target's matching. The controller must be a singleton text name, or a singleton array `[name, detail]`. Every use is listed in the generated feature metadata with its source location. Decoders do not report which features an instance used. A non-singleton controller is Unsupported. |
| `.abnf` | Unsupported | Rejected at the operator span. |
| `.abnfb` | Unsupported | Rejected at the operator span. |

## RFC 9741 control operators

The base-N and numeral operators keep the wire text unchanged. The codec decodes the
text strictly, builds the CBOR data item that the text stands for, and checks that
item against the controller with the controller's own generated matcher. This is
done on both decode and encode.

| Operator | Status | Observable behavior |
|---|---|---|
| `.b64u` | Supported | Base64url (RFC 4648 Section 5) with no padding. Only the URL-safe alphabet is allowed, a length with remainder 1 mod 4 is rejected, and unused trailing bits must be zero. |
| `.b64u-sloppy` | Supported | Same as `.b64u`, but unused trailing bits are not checked. |
| `.b64c` | Supported | Classic base64 (RFC 4648 Section 4) with the padding that is required to reach a multiple of 4. Only the classic alphabet is allowed, and unused trailing bits must be zero. |
| `.b64c-sloppy` | Supported | Same as `.b64c`, but unused trailing bits are not checked. |
| `.b32` | Supported | Base32 (RFC 4648 Section 6) with no padding and the uppercase alphabet `A-Z2-7`. The length mod 8 must be 0, 2, 4, 5, or 7, and unused trailing bits must be zero. |
| `.h32` | Supported | Base32hex (RFC 4648 Section 7) with no padding and the uppercase alphabet `0-9A-V`. Same length and bit rules as `.b32`. |
| `.hex` | Supported | An even number of hex digits, in either case. |
| `.hexlc` | Supported | Lowercase hex digits only. |
| `.hexuc` | Supported | Uppercase hex digits only. |
| `.b45` | Supported | RFC 9285 alphabet. Groups of 3 characters give 2 bytes and a final group of 2 gives 1 byte. A length with remainder 1 mod 3 is rejected, and a group value above 65535 (3 characters) or 255 (2 characters) is rejected. |
| `.base10` | Supported | The text must match `0\|-?[1-9][0-9]*`. Its value becomes a CBOR integer when it lies in `-2^64..2^64-1` and a preferred-serialization bignum (tag 2 or 3) otherwise. That item is then checked against the controller. |
| `.printf` | Supported (folded), for the subset in the next row | The controller must be a singleton array: a format string plus singleton arguments. Conversions: `%%`, `d`, `i`, `u`, `o`, `x`, `X`, `b`, `B`, `c`, and `s`. Flags: `-`, `+`, space, `#`, `0`. Width and precision must be decimal digits. Formatting follows C23 7.23.6.1. `c` formats one Unicode scalar value as UTF-8 and `s` interpolates UTF-8 text. The result is a text literal. |
| `.printf` outside that subset | Unsupported | Rejected: non-singleton arguments, floating conversions (`a A e E f F g G`), `*` width or precision, and length modifiers. `p` and `n` are rejected because RFC 9741 forbids them. |
| `.json` | Supported | The text must be exactly one RFC 8259 JSON text. It is converted following RFC 8949 Section 6.2 with these choices. A number written with no fraction and no exponent becomes an integer: major type 0 or 1 inside `-2^64..2^64-1`, otherwise a bignum in tag 2 or 3. Every other number becomes binary64 rounded to nearest even and is encoded at its shortest exact width; a number that overflows is a mismatch. An escaped lone surrogate is a mismatch. A duplicate object member name is a mismatch. The converted item is then checked against the controller. |
| `.join` | Supported, for the arrangement in the next row | The controller must be an array whose entries each occur exactly once, with no group choices. Singleton string entries are markers. Each variable entry must be separated from the next variable entry by at least one non-empty marker. Matching tries every placement of the markers, so it is exact for this arrangement, and the work counts against `Limits`. The result kind is the kind of the first element. A text result must be valid UTF-8 even when the pieces are not. When every entry is a singleton, the result folds to a literal. |
| `.join` outside that arrangement | Unsupported | Rejected: adjacent variable entries, entries that repeat or are optional, group choices, and entries that are not strings. |

## RFC 8949 codec policy

### Decoding

Every decode checks all of the following. None of these checks can be turned off.

| Check | Reference | Behavior |
|---|---|---|
| Well-formedness | Sec. 3, App. F | The decoder rejects: additional information 28 to 30; indefinite length on major types 0, 1, and 6; a break outside an indefinite item; `0xf8` followed by a value below 32; truncation at any byte; an odd number of items in an indefinite map; and indefinite string chunks that are indefinite themselves or have a different major type. |
| Exactly one item | Sec. 1.2 ("well-formed") | `decode` requires the input to be used up. Trailing bytes are malformed. Only `decodePrefix` returns the count of bytes consumed and accepts more input after it. |
| UTF-8 | Sec. 5.3.1 | Every text string must be valid UTF-8: no overlong forms, no surrogates, nothing above U+10FFFF. In an indefinite text string each chunk must be valid on its own. |
| Duplicate keys | Sec. 5.3.1, 5.6.1 | Rejected under generic data-model equivalence. Integers compare by value whatever their encoded width. `-0.0` equals `0.0`. NaNs are equal when their significands, zero-extended on the right to 64 bits, are equal. An integer never equals a float. Text never equals bytes. Maps compare without regard to pair order. Tags compare by number and content. |
| Simple values | Sec. 3.3 | Two-byte simple values 24 to 31 are malformed. Unassigned simple values are valid data items. The schema decides whether they match. |
| Tag content | Sec. 5.3.2 | The schema decides. The runtime checks no tag content beyond what the CDDL says; for example, `tdate` content is not parsed as RFC 3339. |
| Variation tolerance (default) | Sec. 4.1 | Accepted: integer, length, and tag arguments longer than necessary; floats wider than necessary; indefinite lengths; any map order. |
| Deterministic-input mode | Sec. 4.2.1 | An option in `DecodeOptions`. It also rejects: any non-shortest argument, any float that a shorter width would preserve (the NaN rule included), any indefinite length, and map keys that are not strictly ascending in bytewise order of their encodings. Schema matching is unchanged. |
| Limits | Sec. 10 | Depth, item count, string bytes, total allocation, and matching work are all limited. Lengths are checked against the remaining input before anything is allocated. Exceeding a limit is a limit error, never a schema mismatch. |

### Encoding

The encoder always produces core deterministic encoding (Section 4.2.1). It has no
options that weaken this.

| Rule | Behavior |
|---|---|
| Arguments | Shortest form for integers, lengths, and tag numbers. |
| Lengths | Always definite. |
| Map keys | Sorted in bytewise lexicographic order of their deterministic encodings. This is not RFC 7049 length-first order. A duplicate key, compared by Section 5.6.1, is an encode error. |
| Floats | The shortest of binary16, binary32, and binary64 that keeps the value. This applies to `float32` and `float64` members too, because representation types limit values, not widths. `-0.0` keeps its sign. A NaN is encoded at the shortest width that reconstructs its payload when zero-extended on the right; the payload is never canonicalized. |
| Integers and bignums | An integer becomes major type 0 or 1. Tags 2 and 3 appear only where the schema puts a bignum. Their byte-string content is emitted exactly as stored; leading zero bytes are kept because they are part of the byte-string value. |
| Integer versus float | A value is never converted between integer and float. |
| Validity | Before any output is reported as successful, the encoder checks that the item matches the schema, including PEG projection, literals, controls, and occurrence bounds. An encoder never emits bytes its own decoder would reject. |

## Unsupported constructs

Whenever an Unsupported row applies:

- The diagnostic has error severity and an `E05xx` code. Its primary span covers the
  operator, escape, directive, or construct. It names the construct and the RFC
  section, and it adds a note for the rule (and the generic instantiation chain, if
  any) through which the construct is reached.
- The diagnostic is reported even if no root reaches the construct, so a schema
  never depends on reachability to pass.
- `generate` writes no output. With `-o`, the existing file is not touched.
- `--opaque <rule>` is the only override. It replaces the whole rule, never part of
  one, and always emits a warning.
