# CDDL to Zig mapping

Generation starts from the normalized semantic model. A construct that cannot be
represented exactly by the mappings below fails planning; it is never widened or
silently omitted. See [standards.md](standards.md) for the support boundary.

## Public declarations

Each non-prelude, non-generic named type rule produces two public declarations:

```zig
pub const Packet = /* native mapped type */;
pub const PacketCodec = /* codec for Packet */;
```

CDDL rule names become PascalCase. Map labels and named array entries become
snake_case. Invalid Zig identifier bytes are treated as word separators;
keywords, primitive names, digit-leading names, generated-private names, and
collisions are escaped or deterministically suffixed.

Group rules and generic templates are implementation details and are not exported.
A concrete generic use is monomorphized into the containing rule's type graph.

## Scalar types

| CDDL set | Zig storage |
|---|---|
| `uint`, `#0` | `u64` |
| `nint`, `int`, `#1` | `i65` |
| float sets | `f64` |
| `tstr`, `#3` | `[]const u8` |
| `bstr`, `#2` | `[]const u8` |
| `bool` | `bool` |
| `null`, `nil`, `undefined` | `void` |
| numeric literal/range | `i65` or `f64`, checked by the codec |
| text/byte literal | `[]const u8`, checked byte-for-byte |

`i65` is intentional: CBOR major types 0 and 1 together span
`-18446744073709551616...18446744073709551615`.

A representation head with no more specific native form uses a small wrapper
around `cddl_runtime.Value`. This is explicit in the generated type; it is not an
unchecked `any` path. The codec still validates the complete head constraint.

## Arrays and maps

A supported group becomes a struct. Array fields follow item order. Map fields
use their constant schema keys, independent of wire order.

```cddl
packet = {
  id: uint,
  ? label: tstr,
  data: [* int],
}
```

maps to the equivalent of:

```zig
pub const Packet = struct {
    id: u64,
    label: ?[]const u8 = null,
    data: struct {
        field_0: []const i65 = &.{},
    },
};
```

Occurrence mapping:

| Bounds | Zig field |
|---|---|
| exactly one | `T` |
| zero or one | `?T = null` |
| any other finite or unbounded range | `[]const T` |

Slice lengths are checked against both bounds during validation and encoding.
The decoder checks the same bounds before materializing native values.

Supported maps require unique compile-time constant keys and at most one value
per key. Dynamic keys and repeated key occurrences fail planning.

## Choices

- One alternative aliases that alternative's type.
- Prelude representation-head choices such as `int`, `float`, and `bool` use the
  native scalar while retaining the choice constraints in the codec matcher.
- Other choices become `union(enum)` with stable `choice_0`, `choice_1`, ... tags
  in source order.
- An empty choice maps to `noreturn` and can never be decoded or encoded.

On decode, alternatives are tried in source order. On encode, the selected union
tag identifies the alternative and its payload is validated against that
alternative.

## Tags and representation heads

A tag maps to:

```zig
struct {
    number: u64,
    content: Content,
}
```

A static tag initializes `number` to the schema value. A dynamic tag-number type
is validated against its controller. The content uses its own native mapping.

Static major types map to their corresponding scalar, slice, or runtime container
shape. Simple values 20/21 map to `bool`, 22/23 to `void`, floats to `f64`, and
other static simple values to `u8`.

## Controls

Controls preserve the target's storage type and add matcher predicates. They do
not add unchecked metadata fields. `.default` does not synthesize a missing value;
it validates the target while optionality remains represented by the containing
field.

`.cbor` retains the outer byte string. Validation decodes one nested CBOR item and
matches it against the controller.

## Codec API

For a generated `Packet`:

```zig
pub fn PacketCodec.validate(
    allocator: std.mem.Allocator,
    value: Packet,
) cddl_runtime.Error!void;

pub fn PacketCodec.encode(
    allocator: std.mem.Allocator,
    value: Packet,
) cddl_runtime.Error![]u8;

pub fn PacketCodec.decode(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: cddl_runtime.DecodeOptions,
) cddl_runtime.Error!PacketCodec.Decoded;
```

`encode` returns bytes owned by `allocator`. It emits RFC 8949 core deterministic
CBOR. `decode` requires exactly one complete CBOR item; trailing bytes are an
error.

`Decoded` contains:

```zig
pub const Decoded = struct {
    value: Packet,

    pub fn deinit(self: *Decoded) void;
};
```

Its arena is private. `value` and every nested slice are valid until `deinit`.
The decoded value does not borrow the input.

## Validation path

Generated codecs use one private descriptor graph for all three operations:

1. Native values are converted to a private `cddl_runtime.Value` tree.
2. The descriptor matcher checks literals, ranges, occurrences, keys, heads, and
   controls.
3. Encoding passes the validated value to the deterministic runtime encoder.
4. Decoding obtains a runtime value, matches it, then materializes the native
   public type in the returned arena.

The runtime-value bridge is private. Public APIs expose the native mappings above.

## Runtime module and ABI

Generated source imports `cddl_runtime` by default. Change the import name with
`generate --runtime-import <name>`. Every generated module contains a comptime
check against runtime ABI version 1.

`cddl-zig runtime -o <directory>` writes the exact runtime source set used by the
executable; `<directory>/root.zig` is the module root.

## Determinism

For identical schema bytes and options, generation preserves source ordering and
uses deterministic collision suffixes. Generated code contains no timestamps,
absolute paths, random values, or allocator-dependent ordering. The generator
parses and renders its output with `std.zig.Ast` before returning it.
