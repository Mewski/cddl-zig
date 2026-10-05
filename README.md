# cddl-zig

`cddl-zig` compiles a CDDL schema into Zig 0.16 types and CBOR codecs. Generated
code uses native Zig structs, optionals, slices, scalar types, and tagged unions;
it validates the schema on both decode and encode. The companion `cddl_runtime`
module implements strict RFC 8949 decoding and core deterministic encoding.

The project has no package dependencies.

## Requirements

- Zig 0.16.0

## Build

```sh
git clone https://github.com/Mewski/cddl-zig.git
cd cddl-zig
zig build
zig build test
```

The executable is installed at `zig-out/bin/cddl-zig`.

## Quick start

Given `packet.cddl`:

```cddl
packet = {
  id: uint,
  ? label: tstr,
  data: [* int],
}
```

Generate a Zig module and vendor the matching runtime:

```sh
cddl-zig check packet.cddl
cddl-zig generate -o src/packet.zig packet.cddl
cddl-zig runtime -o src/cddl_runtime
```

Expose `src/cddl_runtime/root.zig` to generated code as the module named
`cddl_runtime`. A build file can do that directly:

```zig
const runtime = b.addModule("cddl_runtime", .{
    .root_source_file = b.path("src/cddl_runtime/root.zig"),
    .target = target,
    .optimize = optimize,
});
const packet = b.addModule("packet", .{
    .root_source_file = b.path("src/packet.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "cddl_runtime", .module = runtime }},
});
```

The schema above exports `Packet` and `PacketCodec`:

```zig
const generated = @import("packet");

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
```

Run `cddl-zig help <command>` for the complete option set.

- `check` runs parsing, semantic analysis, codec planning, and source generation,
  but writes no generated source.
- `generate` writes to stdout by default. `-o <path>` atomically replaces a file
  only when its bytes differ. `--check -o <path>` writes nothing and exits 3 when
  the file is missing or stale.
- `runtime` writes every source file required by `cddl_runtime` into a directory.
  Its `--check` mode detects missing or changed runtime files.
- `explain` prints the stable explanation for an `Edddd` diagnostic code.

Schema commands accept one file or `-` for stdin. `--root <rule>` selects a
non-generic type rule instead of the first rule. Diagnostics support human and
JSON output, bounded retention, explicit color control, and byte-accurate source
locations.

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

The parser and semantic analyzer implement the RFC 8610 core language with the
RFC 9682 grammar and the RFC 8610 Appendix D prelude. The runtime follows RFC
8949 and emits core deterministic CBOR.

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
ordering. The encoder always emits core deterministic CBOR.

## Development

```sh
zig build fmt-check
zig build test
zig build
```

Architecture and invariants are in [docs/architecture.md](docs/architecture.md).

## License

[The Unlicense](LICENSE). This software is dedicated to the public domain.
