# cddl-zig

`cddl-zig` compiles a CDDL schema into Zig 0.16 types and CBOR codecs. Generated
code uses native Zig structs, optionals, slices, scalar types, and tagged unions;
it validates the schema on both decode and encode. The companion `cddl_runtime`
module implements strict RFC 8949 decoding and core deterministic encoding.

The project has no package dependencies.

## Requirements

- Zig 0.16.0

## Install the CLI

For a user-local release build:

```sh
git clone https://github.com/Mewski/cddl-zig.git
cd cddl-zig
zig build -Doptimize=ReleaseSafe --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
cddl-zig version
```

`zig build` installs into `zig-out` by default. `--prefix "$HOME/.local"` uses
Zig's standard installation-prefix mechanism and places the executable in
`$HOME/.local/bin`; add that directory to the shell profile for persistent use.

For checkout-local development instead:

```sh
zig build
./zig-out/bin/cddl-zig version
```

`zig fetch` manages source dependencies; it does not install command-line tools.

## Quick start

Given `packet.cddl` in an application's root:

```cddl
packet = {
  id: uint,
  ? label: tstr,
  data: [* int],
}
```

Generate the Zig module:

```sh
mkdir -p src
cddl-zig check packet.cddl
cddl-zig generate -o src/packet.zig packet.cddl
```

Add `cddl-zig` to the application's package manifest:

```sh
zig fetch --save=cddl_zig git+https://github.com/Mewski/cddl-zig.git
```

`zig fetch --save` writes the dependency URL and content hash to
`build.zig.zon`. Commit that manifest so the fetched package contents remain
reproducible.

Generated source imports the runtime as `cddl_runtime`. Inside
`build(b: *std.Build)`, using the application's existing `target`, `optimize`,
and `exe`, add:

```zig
const cddl = b.dependency("cddl_zig", .{
    .target = target,
    .optimize = optimize,
});
const packet = b.addModule("packet", .{
    .root_source_file = b.path("src/packet.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "cddl_runtime", .module = cddl.module("cddl_runtime") },
    },
});
exe.root_module.addImport("packet", packet);
```

The dependency also exports `cddl_zig` for programs that invoke the compiler API
directly:

```zig
exe.root_module.addImport("cddl_zig", cddl.module("cddl_zig"));
```

Creating a named module does not automatically expose it to an executable;
`addImport` supplies the corresponding `@import` dependency edge.

The schema above exports `Packet` and `PacketCodec`. This complete Zig 0.16
example encodes and decodes one value:

```zig
const std = @import("std");
const generated = @import("packet");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const values = [_]i65{ 1, -2 };
    const packet: generated.Packet = .{
        .id = 7,
        .label = "ready",
        .data = .{ .field_0 = &values },
    };

    const bytes = try generated.PacketCodec.encode(allocator, packet);
    defer allocator.free(bytes);

    var decoded = try generated.PacketCodec.decode(allocator, bytes, .{});
    defer decoded.deinit();
    std.debug.assert(decoded.value.id == packet.id);
}
```

`decode` returns an arena-owning `Decoded`. Its `.value` and all nested slices
remain valid until `Decoded.deinit`. `encode` returns allocator-owned bytes.
`validate` checks a native value without producing CBOR.

## Commands

```text
cddl-zig check [options] <file>
cddl-zig generate [options] <file>
cddl-zig runtime -o <directory> [--check]
cddl-zig explain <CODE>
cddl-zig help [<command>]
cddl-zig version
```

Run `cddl-zig help <command>` for the complete option set.

- `check` runs parsing, semantic analysis, codec planning, and source generation,
  but writes no generated source.
- `generate` writes to stdout by default. `-o <path>` atomically replaces a file
  only when its bytes differ. `--check -o <path>` writes nothing and exits 3 when
  the file is missing or stale.
- `runtime` writes every source file required by `cddl_runtime` into a directory.
  Its `--check` mode detects missing or changed runtime files, ignores unrelated
  files, writes nothing, and exits 3 when the runtime is stale.
- `explain` prints the stable explanation for an `Edddd` diagnostic code.
- `help` prints general or command-specific usage; `version` prints the package
  version.

Schema commands accept exactly one file or `-` for stdin. Generated modules
export every non-generic type rule. The root—the first rule by default, or the
rule named by `--root <rule>`—must be a non-generic type rule; choosing a root
validates that requirement but does not filter the generated exports.

Diagnostics support bounded retention, byte-accurate locations, and explicit
color control. `--diagnostics json` writes one JSON document to stderr for schema
and I/O outcomes. Argument-parsing errors remain plain text; later usage errors,
including an output path that resolves to the input, use the JSON document.

Exit codes are 0 for success, 1 for schema diagnostics, 2 for usage or an unknown
diagnostic code, 3 for stale `--check` output, 4 for I/O or input-limit failures,
5 for out of memory, and 70 for an internal error. `cddl-zig help` is the
authoritative command summary.

## Generated mapping

| CDDL | Generated Zig |
|---|---|
| `uint` | `u64` |
| `int` | `i65` |
| float types | `f64` |
| `tstr`, `bstr` | `[]const u8` |
| fixed array or map group | `struct` |
| `? entry` | optional field |
| repeated array entry | slice field |
| heterogeneous choice | `union(enum)` |
| prelude scalar choice (`int`, `float`, `bool`) | native scalar |
| tag | struct containing `number` and `content` |

Public rule names use PascalCase. Field names use snake_case. Collisions are
resolved deterministically. Generated modules check `cddl_runtime.abi_version`
at compile time.

See [docs/mapping.md](docs/mapping.md) for ownership and mapping details.

## Standards and current boundary

The frontend parses and normalizes the RFC 8610 core language using the RFC 9682
grammar and the RFC 8610 Appendix D prelude. The generated-code support boundary
is narrower and explicit below. The runtime follows RFC 8949; its high-level
value encoder emits core deterministic CBOR.

Generation deliberately rejects constructs for which this backend does not yet
have an exact native mapping. Current hard errors include recursive type graphs,
group alternatives, repeated group splices, dynamic or repeated map keys,
`.regexp`, `.cborseq`, and non-RFC-8610 control vocabularies. No unsupported
construct is widened to `any` or silently ignored.

The exact accepted and rejected sets are documented in
[docs/standards.md](docs/standards.md).

## Runtime

`cddl_runtime` can also be used independently. Its public API includes:

- `Encoder`, `Decoder`, `Value`, and `Value.Entry`
- `encodeValueAlloc`, `decodeValue`, and `validate`
- `DecodeOptions` with optional deterministic-input checking
- finite depth, item, string, cumulative-allocation, and work limits
- RFC 8949 map-key equivalence and duplicate-key rejection

The decoder accepts valid non-preferred CBOR by default. Set
`require_deterministic` to reject non-preferred arguments, float widths, and map
ordering. Generated codec `encode`, `encodeValueAlloc`, and `Encoder.writeValue`
emit core deterministic CBOR. `MapBuilder` orders encoded keys and rejects
equivalent keys, but callers must supply deterministic key and value encodings.
Lower-level `Encoder` methods such as `writeEncoded`, `writeFloat32`, and
`writeFloat64` deliberately preserve caller-supplied bytes or widths;
`writeMapHeader` requires keys to follow in deterministic order.

## Development

```sh
zig build fmt-check
zig build test
zig build
```

Architecture and invariants are in [docs/architecture.md](docs/architecture.md).

## License

[The Unlicense](LICENSE). This software is dedicated to the public domain.
