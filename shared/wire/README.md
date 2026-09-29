# Wire schema

`schema.wire` describes every message on the wire (ADR 0018 section 2). `server/cmd/wiregen` reads it and writes the Go and C++ codecs. Regenerate with `scripts/wiregen.sh`. `scripts/wiregen_check.sh` fails when the committed output is stale.

## Grammar

One declaration or field per line. `#` starts a comment. Names are declared before use.

```
handle PlayerId                              # entity id type
quant pos min -4096 max 4096 per_unit 100    # fixed-point number
enum RefuseReason {                          # enum, explicit values
  cooldown = 6
}
struct Pair {                                # reusable record
  who NpcId
  weight f32
}
message pose = 2 on state s2c {              # message <name> = <id> on <channel> <direction>
  id PlayerId                                # <field> <type>
  x pos
}
```

- Message ids are unique across both directions and never reused. A retired id stays retired.
- Channels and their directions are fixed by ADR 0018 section 1.3. `state` and `events` are `s2c`. `input` and `intents` are `c2s`. A mismatch is a generator error.
- Type names (handles, enums, structs) are PascalCase. Messages, fields, quants, and enum members are snake_case.
- `where` after a field type and `rule` lines inside a block are reserved for declared rules (ARM-350).

## Types and encoding

All values are little-endian and byte-aligned. A varint is canonical unsigned LEB128 capped at 32 bits. The decoder rejects overlong forms.

| Type | Go | C++ | Bytes |
|---|---|---|---|
| `u8` `u16` `u32` `u64` | `uint8`... | `std::uint8_t`... | fixed width |
| `i8` `i16` `i32` `i64` | `int8`... | `std::int8_t`... | fixed width, two's complement |
| `bool` | `bool` | `bool` | one byte, 0 or 1 |
| `f32` | `float32` | `float` | IEEE 754 bits. NaN and infinity are refused both ways. |
| quant name | `float64` | `double` | `round(v * per_unit) - min * per_unit` as the smallest of u8, u16, or u32 that holds `(max - min) * per_unit`. Out-of-range and non-finite values are refused. |
| `string(N)` | `string` | `std::string` | varint byte length at most N, then UTF-8 bytes |
| enum name | named `uint32` | `enum class : std::uint32_t` | varint. Undeclared values are refused. |
| `list(T, N)` | `[]T` | `std::vector<T>` | varint count at most N, then elements |
| handle name | struct `{Index, Gen uint32}` | struct `{index, gen}` | varint index, then varint generation |
| struct name | struct | struct | fields in order |

A message is its varint id followed by its fields. One decode call takes exactly one message. Leftover bytes are an error.

Each handle is its own type in both languages, so an `NpcId` does not compile where a `PlayerId` is expected. The generation lets a reused index never alias the old entity (ADR 0018 section 3.4).

## Schema hash

`SchemaHash` (Go) and `schema_hash` (C++) are the first 8 bytes, read big-endian, of SHA-256 over the canonical form. The canonical form lists handles, quants, enums, structs, and messages in that order, each in source order, one line per header, member, or field, with single spaces and no comments. Whitespace and comments therefore do not change the hash. Every name, id, type, bound, and field order does. `go run ./cmd/wiregen canon` (from `server/`) prints the canonical form.

## Files

- `testdata/probe.wire` is a fixture that uses every field type. It generates `server/internal/wire/probe` and `marque/wire/gen/probe.hpp`, and exists only for tests.
- `vectors/*.vec` hold the committed encodings. The Go and C++ tests build the same values and assert these bytes.
- `go run ./cmd/wiregen/dump <hex>...` (from `server/`) prints encoded messages as text.
