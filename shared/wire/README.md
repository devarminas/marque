# Wire schema

`schema.wire` describes every message on the wire (ADR 0018 section 2). `server/cmd/wiregen` reads it and writes the Go and C++ codecs. Regenerate with `scripts/wiregen.sh`. `scripts/wiregen_check.sh` fails when the committed output is stale.

`wiregen gen [-root <dir>] [-src <dir>]` (from `server/`) writes every target's generated files under `-root` (default `..`), reading the schemas from `-src` (default `..`). `wiregen canon [schema]` prints the canonical form `SchemaHash` hashes; with no argument it reads `shared/wire/schema.wire`. Paths are relative to the repository root, which is the parent of the `server` module.

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
- `scripts/wiregen.sh` writes every file's text into `server/internal/wire/vectors_gen_test.go`, a source file of the test package. go test ignores files outside the module when it decides whether a cached result still holds, but never ignores its own package's sources, so a regenerated vector always reruns the test. `scripts/wiregen_check.sh` fails when that file does not match `vectors/`, so an edit that skipped regeneration fails the gate instead of passing on the old copy.

## Fuzzing

Every channel decoder of both schemas runs under a fuzzer: Go's native fuzzer (`Fuzz<Schema><Channel>` in `server/internal/wire/fuzz_test.go`) and libFuzzer with ASan and UBSan (`native/fuzz`, built by the opt-in CMake option `MARQUE_FUZZ` under clang). Both seed from the vectors on their channel. A run fails when an input crashes the decoder, or when an input decodes but does not encode back to its own bytes.

`scripts/wire_fuzz.sh <seconds>` builds the libFuzzer targets in `native/build/wire-fuzz` and runs all 16 fuzzers at once for that many seconds each. It prints each run's final stats line and exits 1 if any run found a crash. Logs and any crashing input land in `native/build/wire-fuzz/logs`. Go writes a crashing input to `server/internal/wire/testdata/fuzz`.

## Runtime codec

`server/internal/wire/codec` (Go) and `native/core/{include,src}/wire/codec` (C++) are the
hand-written runtime the generated message code builds on; they are not generated. Both keep only
the first error a `Writer` or `Reader` hits and turn every later call into a no-op, so generated
code needs no per-field checks. A varint that is overlong, or whose fifth byte carries bits above
`0x0f`, is refused so every value has exactly one encoding. `Reader.Count`/`count` fails with
truncated before the decoder can size an allocation from a count whose claimed elements cannot fit
in the remaining bytes — proved by `TestHostileCountFailsBeforeAllocating` (Go) and
`wire_hostile_count_test.cpp` (C++), which counts heap allocations around the decode. C++
`valid_utf8` accepts exactly what Go's `utf8.Valid` accepts: no overlong forms, no surrogates,
nothing above U+10FFFF.

## Files

- `testdata/probe.wire` is a fixture that uses every field type and every rule kind. It generates `server/internal/wire/probe` and `marque/wire/gen/probe.hpp`, and exists only for tests. Its `crowd` message carries the hostile-count tests.
- `vectors/starter.vec`, `vectors/probe.vec`, and `vectors/rules.vec` are the conformance vectors.
- `go run ./cmd/wiregen/dump <hex>...` (from `server/`) prints encoded messages as text. It lives in its own package apart from `wiregen` so the generator never imports the package it generates: a broken generated package must not stop regeneration.

## Owner facts and intents

ARM-357 reserves message id 4 permanently. Its starter refusal fixture migrated to id 138. Id 4 has no decoder and must not be reused.

Events 128 through 138 carry stable stream incarnation, event sequence, and producing tick. They represent inventory, equipment, class, skills, quest log, dialog, party, invite, admin reply, cooldown, and refusal respectively. Refusal names input or intent origin and that source's initiating sequence. Reason numbers 1 through 7 retain their original assignments. JSON framing failures, ignored unknown messages, unknown senders, and the unused degenerate constant have no valid decoded-intent refusal variants. Protocol error number 8 remains reserved for defensive admin failures. With the sole built-in memStore and validated built-in NPC catalog paths, it has no healthy decoded-action producer. adminGive checks live targets and converts inventory full separately; its remaining store error branch requires an invariant failure. adminSpawn validates kind, faction, max HP, archetype, and coordinates before its remaining error branch. Tests cover the 42 reachable reasons and do not manufacture these failures.

Reliable tick close 139 names stream, current connection epoch, producing boundary tick, final event sequence, and actual flushed state item count. It certifies a scheduled slice, including an empty slice. It does not certify a full world baseline. Resume boundary 140 announces retained application cursor and next intent sequence. It does not authorize application commit by itself. Dialog clear 141, party clear 142, and invite clear 143 carry explicit clear values.

Intents 256 through 273 cover pickup, drop, equip, unequip, gather, self use, player attack, respawn, self cast, talk, dialog option, give, party invite, party accept, party decline, party leave, party kick, and admin. Application commit is 274. Station use 275, NPC attack 276, player cast 277, and NPC cast 278 make target variants explicit using the verified plain grammar. Movement stays on input id 1. Player move_to has no entry.

Inventory has 28 unique slots, each below its declared size. Equipment preserves its fixed six-name worn layout as a bounded unique name list, separately from occupied slots. Equipment occupied slots and class missing slots have six unique named slots. A party has at most four unique members and includes its leader. Skill and quest lists have at most 64 unique ids. Dialog has at most 16 lines and 16 unique options. Class missing tools has at most 16 unique kinds. Catalog ids and kinds have 64 bytes, worn names 32 bytes, quest titles 256 bytes, objectives 512 bytes, dialog lines 1024 bytes, admin input 1024 bytes, and admin replies 8192 bytes. UTF-8 bytes determine each string bound. Producers exceeding a bound fail encoding; they never truncate.

The checked catalogs contain two abilities, five classes, five skills, and two quests. Their longest stored string is 17 bytes. Inventory and worn counts are existing game limits. Text generated from catalogs and admin replies is checked at the adapter boundary. These are representation limits, not an assumption that future catalogs may grow without validation.

The owner-thread session collection defaults to 5000 live sessions, 262144 encoded journal bytes, 4096 facts, 1024 offered tick boundaries, and 1500 suspended ticks per session. Encoded-byte limits exclude Go allocation overhead and the retained domain values. Packet receipt never releases the journal. Application commit must match an offered stream, epoch, tick, and event end. Duplicate last-command checking covers only the most recently retained canonical intent. Input samples use a separate monotonic high-water and reject duplicate or older jump edges and wishes.

A caller supplies strictly increasing stream incarnation ids to each session collection. A network resume keeps that stream and increments its epoch. Cutover must allocate incarnations across process lifetimes and supply authenticated account and session identity. An expired session cannot resume. Token admission, fresh traffic keys, reader epoch binding, certified multi-part full reset, and the production client publication assembler belong to ARM-363.

Capacity failure returns the explicit retired owners after preserving complete ticks for unaffected owners. The caller releases those game owners and continues with the accepted owner journals. Repeating the same batch is safe before removing the returned owner mappings. Invalid producer data changes no journal. Session expiry returns handles for World.ReleaseOwner. Pending actions continue while suspended, matching the existing game's suspension behavior.
