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
- Fields and enum members may not be C++ keywords. A field may not be named `message_id`, `channel`, `append`, `string`, or `build`. Type and message names may not become a name the Go generator emits (`Message`, `SchemaHash`, `StateMsg`, `DecodeState`, `DecodeNextState`, and the same for each channel), and a struct or message named `X` also claims `XFields`.
- A struct has at least one field, so every list element costs at least one byte.
- A quant needs `max(|min|, |max|) * per_unit` at most 2^53, so `v * per_unit` is exact in a double.

## Rules

A field may end with a `where` clause, and a struct or message may hold `rule` lines. The generated decoder checks every rule and fails with `ErrRule` (C++ `codec::Error::rule`). The encoder and `Build` run the same checks in the same order, so they refuse a value with the same error the decoder gives for its bytes.

```
struct BagSlot {
  slot u8 where 0..39                      # range
  item ItemId
}
message inventory = 5 on events s2c {
  size u8 where 1..40
  slots list(BagSlot, 40) where unique(slot)   # unique by a struct field
  rule slots.slot < size                   # relation; a list side means every element
}
message party = 4 on events s2c {
  leader PlayerId
  members list(PlayerId, 5) where unique   # unique by whole value
  rule leader in members                   # membership
}
message pick = 7 on intents c2s {
  option Option where {accept_quest, stop_talking}   # enum subset
}
```

A `where` clause is one or more terms joined by `and`, at most one of each kind.

| Term | Applies to | Holds when |
|---|---|---|
| `<lo>..<hi>` | integer, quant, or a list of either | the value (every element, for a list) lies in `lo..hi`, both inclusive |
| `{a, b, ...}` | enum, or a list of enums | the value (every element) is one of the named members |
| `unique` | list whose element holds no list, f32, or quant | no two elements are equal |
| `unique(<field>)` | list of structs | no two elements have the same value in that field |

A `rule` line is `rule <left> <op> <right>`. Each side is a field of the block, or `<field>.<sub>` where the field is a struct or a list of structs.

| Op | Sides | Holds when |
|---|---|---|
| `<` `<=` | integers or quants | the left side is below (or at most) the right side |
| `==` `!=` | integers, bools, quants, strings, enums, or handles | the sides are equal (or differ) |
| `in` | a single value on the left, a list on the right | some element equals the left side |

- Both sides of a rule have the same type. `PlayerId` never compares with `NpcId`, and `u8` never compares with `u16`.
- For `<`, `<=`, `==`, and `!=`, at most one side is a list. A list side means the relation holds for every element, so an empty list passes. `in` against an empty list fails.
- Range bounds are decimals. An integer bound lies inside the field's type. A quant bound lies inside the quant and on its grid, so `where -8..5.25` needs `per_unit` 4 or a multiple of it.
- Quants compare by their wire integer, never as doubles. A rule therefore sees exactly the value the peer decodes.
- f32 takes part in no rule. A list with a `unique` term has a bound of at most 256, because the check compares every pair.
- A rule names fields of its own block only. It cannot reach into another message.
- The canonical form prints each `where` clause on its field's line and each `rule` line after the fields, so every rule changes `SchemaHash`.

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
| `list(T, N)` | `[]T` in `XFields`, `codec.List[T]` from the getter | `std::vector<T>` | varint count at most N, then elements. The decoder refuses a count whose elements cannot fit in the remaining bytes before it allocates. |
| handle name | struct `{Index, Gen uint32}` | struct `{index, gen}` | varint index, then varint generation |
| struct name | read-only record | read-only record | fields in order |

A message is its varint id followed by its fields.

## Generated records are read-only

Every struct and message `X` generates two types in each language.

- `XFields` is a plain record with public fields. You fill it and call Go `XFields{...}.Build()` or C++ `X::build(XFields{...})`. Build runs every check the encoder runs and returns the same error a decoder gives for the same value's bytes.
- `X` holds a validated copy behind getters. Go stores it in an unexported field and exposes `v.Leader()`, with lists returned as `codec.List[T]` (`Len`, `At`, `All`), a view with no setter. C++ keeps it private and exposes `const T& leader() const`. Decoding and Build are the only ways to fill an `X`, so code after the decoder never checks it again.
- Go Build copies each list, so changing the caller's slice afterwards cannot change the message. C++ build takes `XFields` by value, which owns its vectors.
- The zero value (Go `X{}`, a default-constructed C++ `X`) is the one value Build never saw. Append and encode still run every check, so they refuse a zero value that breaks a rule and leave the output buffer as it was.

## Decoding by channel

Each channel has its own message interface (Go `StateMsg`, C++ `StateMsg` variant) and its own decoders. A decoder refuses an id that belongs to another channel with `ErrUnknownMessage`.

- `DecodeNextState(r *codec.Reader)` (C++ `decode_next_state(codec::Reader&)`) reads one message and leaves the reader after it. Loop while `r.Len() > 0` (C++ `r.remaining()`) to read many messages from one payload.
- `DecodeState(b []byte)` (C++ `decode_state(span)`) reads one message and fails with `ErrTrailing` if any byte is left.

The same pair exists for `events`, `input`, and `intents`. A channel with no messages still gets its interface and decoders. In C++ its variant holds only `std::monostate`, because `std::variant<>` is ill-formed.

## Planned: unions and optional fields (ARM-356)

The generator does not accept these yet. This is the grammar and encoding ARM-356 implements.

```
union Target {          # tagged union over handle kinds
  player PlayerId = 1
  npc NpcId = 2
}
message cast = 9 on intents c2s {
  target Target
  focus opt(PlayerId)   # optional field
}
```

- `union Name { member Handle = tag }` declares a sum type. Members are handle types. Tags are explicit u32 values, unique within the union, and never reused, like enum values. The encoding is the varint tag, then the member's handle. An undeclared tag is refused both ways. Go gets a sealed interface that each member handle implements, and a nil value is refused on encode. C++ gets `std::variant<PlayerId, NpcId>`. The minimum wire size is 1 plus the smallest member.
- `opt(T)` wraps any type except another `opt`. The encoding is one presence byte (0 or 1, anything else refused like a bool), then `T` when the byte is 1. Go gets `codec.Opt[T]{V T; Ok bool}`, a value type so decoding allocates nothing. C++ gets `std::optional<T>`. The minimum wire size is 1.

Each handle is its own type in both languages, so an `NpcId` does not compile where a `PlayerId` is expected. The generation lets a reused index never alias the old entity (ADR 0018 section 3.4).

## Schema hash

`SchemaHash` (Go) and `schema_hash` (C++) are the first 8 bytes, read big-endian, of SHA-256 over the canonical form. The canonical form starts with `wire 1`, the codec version, which changes whenever a byte rule changes. It then lists handles, quants, enums, structs, and messages in that order, each in source order, one line per header, member, field, or rule, with single spaces and no comments. Whitespace and comments therefore do not change the hash. Every name, id, type, bound, rule, and field order does. `go run ./cmd/wiregen canon` (from `server/`) prints the canonical form.

## Text form

Go `String()` and C++ `to_text(x)` (per channel, `text_state(m)` and so on) print the same text. A record prints as `name{field:value field:value}`, where `name` is the message's snake_case name or the struct's PascalCase name. Values print as follows.

- Integers print in decimal and bools as `true` or `false`.
- f32 and quants print as Go's `strconv.FormatFloat(v, 'g', -1, 32 or 64)`: the shortest digits that read back to the same value, in exponent form when the decimal exponent is below -4 or at least 6 (`0.0001`, `1.5e-05`, `1e+06`).
- Strings print as Go's `strconv.QuoteToASCII`: `"h\u00e9llo"`.
- Enums print their member name. Handles print as `PlayerId(7/2)`, index then generation.
- Lists print as `[a b c]`.

## Conformance vectors

`vectors/*.vec` hold encoded messages and what each one must decode to. Both the Go test (`server/internal/wire`) and the C++ test (`wire_codec_test`) run every line of every file.

```
# comment
schema probe
accept party events 0401000201000200 party{leader:PlayerId(1/0) members:[PlayerId(1/0) PlayerId(2/0)]}
reject party_leader_outside events 0403000201000200 rule
```

- The `schema` line names the schema the lines after it use: `wire` for `schema.wire` or `probe` for `testdata/probe.wire`.
- `accept <name> <channel> <hex> <text>` must decode on that channel's single-message decoder to exactly `<text>`, and the decoded message must encode back to exactly `<hex>`.
- `reject <name> <channel> <hex> <error>` must fail with that error. The error is the C++ `codec::Error` enumerator name (`truncated`, `trailing`, `unknown_message`, `over_bound`, `non_finite`, `out_of_range`, `bad_bool`, `bad_enum`, `bad_varint`, `bad_utf8`, `rule`). Go maps each name to its `codec.Err...` value.
- `scripts/wiregen.sh` copies the files into `server/internal/wire/testdata/vectors`, and the Go test embeds that copy. go test tracks embedded files, so a vector edit reruns the test instead of hitting the cache. `scripts/wiregen_check.sh` fails when the copy is stale.

## Fuzzing

Every channel decoder of both schemas runs under a fuzzer: Go's native fuzzer (`Fuzz<Schema><Channel>` in `server/internal/wire/fuzz_test.go`) and libFuzzer with ASan and UBSan (`native/fuzz`, built by the opt-in CMake option `MARQUE_FUZZ` under clang). Both seed from the vectors on their channel. A run fails when an input crashes the decoder, or when an input decodes but does not encode back to its own bytes.

`scripts/wire_fuzz.sh <seconds>` builds the libFuzzer targets in `native/build/wire-fuzz` and runs all 16 fuzzers at once for that many seconds each. It prints each run's final stats line and exits 1 if any run found a crash. Logs and any crashing input land in `native/build/wire-fuzz/logs`. Go writes a crashing input to `server/internal/wire/testdata/fuzz`.

## Files

- `testdata/probe.wire` is a fixture that uses every field type and every rule kind. It generates `server/internal/wire/probe` and `marque/wire/gen/probe.hpp`, and exists only for tests. Its `crowd` message carries the hostile-count tests.
- `vectors/starter.vec`, `vectors/probe.vec`, and `vectors/rules.vec` are the conformance vectors.
- `go run ./cmd/wiregen/dump <hex>...` (from `server/`) prints encoded messages as text.
