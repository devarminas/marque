# 0018. Wire format and transport

## Status

Accepted on 2026-10-01. When implemented, this replaces the JSON protocol in `server/internal/net/protocol.go`, the WebSocket hub in `server/internal/net/hub.go`, and the client in `client/scripts/net_client.gd`. The authority rules from ADR 0001 stay unchanged. The client sends wishes, and the server owns pose. The message names from ADR 0003 and ADR 0013 become entries in the schema file.

## Context

Today the client and the server exchange one-key JSON envelopes over one WebSocket. The protocol exists twice, written by hand, once in Go and once in GDScript. It has 29 server messages and 20 client messages. The two copies already disagree. The client treats `hp`, `mana`, and `worn` as optional although the server always sends them, and it recovers from `null` lists that the server should never send.

The server sends every broadcast to every connected client (ADR 0013). Nothing limits a player's view of the world. That cost grows with the square of the player count.

Marque targets sharded worlds with thousands of players per shard, and it is built mostly by AI sessions. The wire has to make bad messages impossible to build or decode, not just unlikely. Browser clients are a non-goal, so the transport can use raw UDP.

## Decision

### 1. Transport is our own reliable-UDP library

The packet limit, ack field, keepalive interval, and timeout below are implemented. [The transport specification](../../shared/wire/transport.md) defines the byte-level rules. [The transport conformance vectors](../../shared/wire/vectors/transport/) cover those rules.

1. **Two implementations.** A pure Go package runs on the server, and a C++ library runs in the client core. Neither calls the other through cgo. Shared conformance vectors (section 8) keep the two in agreement.
2. **Packets.** Every packet has a header followed by channel payloads. The header carries the protocol id, the schema hash, the packet sequence number, the latest received sequence number, and a 32-bit ack field for the 32 packets before it. A packet never exceeds 1200 bytes, so routers never have to split it.
3. **Channels.** One connection carries four channels:

   | Channel | Direction | Delivery | Carries |
   |---|---|---|---|
   | `state` | server to client | Unreliable. A stamp no newer than the newest received state stamp is dropped. Accepted unpublished changes remain staged. | Per-tick world state (section 3). |
   | `events` | server to client | Reliable and ordered. | Owner-scoped facts (section 4). |
   | `input` | client to server | Unreliable. Each packet repeats the last N inputs. | Movement wish and jump edge. |
   | `intents` | client to server | Reliable and ordered. | Every other action, such as attack, cast, pickup, and talk. |

4. **Fragmentation.** Only `events` and `intents` split a message across packets. A `state` payload must fit one packet. Section 3 says how it is trimmed to fit.
5. **Send budget.** Each connection has a byte budget per tick. `events` are never dropped. `state` shrinks to fit what is left. If the `events` backlog passes a fixed limit, the server disconnects the client with `slow_client`, the same reason the hub uses today.
6. **Handshake.** A login service, which does not exist yet, gives the client a connect token over HTTPS. The login service encrypts the token with a key that only it and the shards know. It holds the account id, the shard address, an expiry time, and the session keys. The shard sends a challenge and allocates no connection state until the client answers it. The request is 512 bytes, the challenge is 183 bytes, the response is 199 bytes, and the connect token is 232 bytes. The shard replies only with the challenge, which is smaller than its request. The shard cannot amplify an attack against a faked source address. [The handshake specification](../../shared/wire/transport.md#handshake) defines the exchange.
7. **Encryption.** Both sides encrypt and authenticate every packet after the handshake with ChaCha20-Poly1305. We write the protocol, but we never write crypto primitives. Go uses `golang.org/x/crypto`, and C++ uses libsodium. The session seal carries a 64-bit counter nonce per direction inside its overhead. It rejects replays before the transport's sequence window. Each connection has separate sealing and opening halves that share no state. [The session seal specification](../../shared/wire/transport.md#session-seal) defines these rules.
8. **Liveness.** Each side sends a keepalive when it has sent nothing for 100 ms. A connection that receives nothing for 5 s times out. This replaces `heartbeat_ticks`.
9. **Threading.** On the server, one goroutine reads the UDP socket, decrypts, and hands decoded intents to the tick loop over a channel. The tick loop stays the only owner of game state, as AGENTS.md requires.

### 2. One schema file generates code for both sides

1. **One schema file.** `shared/wire/schema.wire` describes every message. `server/cmd/wiregen`, written in Go, reads it and generates Go and C++ code. We commit the generated files. CI fails when they are stale.
2. **Why a custom schema.** FlatBuffers, Protobuf, and Cap'n Proto describe shapes. They cannot say "the party leader is one of the members", "slot is below inventory size", or "an option id appears once". Our schema declares ranges, enum subsets, uniqueness, and cross-field relations. The generated decoder enforces every declared rule. Decoded records are immutable, so no code after the decoder checks them again. [The schema specification](../../shared/wire/README.md) defines the rules and generated records.
3. **What each message declares.** Each message declares a numeric id that is never reused, its channel, its direction, and its fields. Field types are:
   - Sized integers, `bool`, and `f32`.
   - Quantized positions, stored as fixed-point with a declared range and precision.
   - Strings with a maximum byte length.
   - Enums.
   - Lists with a maximum count.
   - Entity ids with a separate type for each kind (`PlayerId`, `NpcId`, `ItemId`, `NodeId`), so one kind cannot be passed where another is expected.
   - Tagged unions over entity kinds.
   - Optional fields whose absence has a meaning in the game.
4. **Encoding.** Both streams use one binary codec. Values are little-endian and byte-aligned, with variable-length integers for counts and ids. Bit-packing is left for later, and only if measured bytes per tick call for it.
5. **No partial compatibility.** The handshake compares schema hashes and refuses a mismatch. An unknown message id is a protocol error that ends the connection. Client and server ship together, so there are no optional fields for older peers. A field is optional only when its absence has a meaning in the game.
6. **Readable dumps.** `wiregen` also generates a dump tool that prints any packet or recording as text.
7. **Illegal movement cannot be expressed.** The `input` message has quantized `dx` and `dz` and a jump bit, and nothing else. A pose fact or a non-finite number cannot be encoded, so ADR 0003's list of refused keys becomes unnecessary.

### 3. State stream

1. **Interest.** The server divides a shard into grid cells. A client's interest set is every entity in the cells within a radius of its player. Cell size and radius are open (see the open questions below).
2. **Components.** Entity state travels as one `entity` message on the `state` channel, with optional components such as transform, vitals, worn gear, and cast bar. An absent component means unchanged. The transport may trim a payload between items. Separate component messages could therefore deliver an entering entity half-built. [The schema](../../shared/wire/schema.wire) defines the entity message.
3. **Deltas against an acknowledged tick.** For each client, the server remembers the last tick that client acknowledged. Only the newest acknowledged packet advances that tick. The ack bits do not, because the transport acknowledges a datagram even when it drops the datagram's stale state section. [The transport staleness rules](../../shared/wire/transport.md#unreliable-staleness) define that behavior. The server sends only the components that changed since the acknowledged tick. If the client acknowledges nothing for 32 packets, the server sends full state again.
4. **Entering and leaving view.** An entity that enters the interest set arrives with every component. An entity that leaves arrives as a removal entry. Entity handles pair an index with a generation number, so a reused index never looks like the old entity.
5. **Priority.** When a tick's delta does not fit the budget, the server sends the entities with the highest priority first. Distance, being the player's target, and being in the player's party raise priority. A skipped entity gains priority on every tick until it is sent.
6. **Presentation facts.** The server sends swing, cast phase, and gather start (ADR 0013) on the `state` channel as per-entity facts tagged with their tick. The server repeats each fact until the client acknowledges a packet that carried it, for at most 8 ticks. ADR 0013 still holds, so client game logic never branches on them.
7. **Client apply.** The client applies a whole scheduled tick at once and keeps the last two published ticks. A scheduled tick is the bounded state slice actually selected and flushed for that client, including an explicitly certified empty slice. Omitted entities and components remain cached. Completion does not certify full-interest state or inclusion of every event-related world change. Rendering interpolates between published ticks behind a short jitter buffer. The local player is predicted from its own inputs and reconciled to the server pose for the last acknowledged input sequence number.

### 4. Event stream

1. **What goes there.** Inventory, equipment, class, skills, quest log, dialog, party, invites, admin replies, cooldowns, and server refusals. These facts belong to one player and must arrive, in order.
2. **Tick tags and publication.** Every event retains the tick that produced it. The client atomically publishes scheduled state at tick R with the complete ordered prefix of unapplied owner events produced through R. A reliable completion marker certifies that event prefix and the actual scheduled state contents for R, including empty ticks. If an earlier state tick is unavailable, its events may publish with a later received tick. Received but unpublished state changes remain staged until publication because packet acknowledgements may already have advanced the server's component baselines. Owner facts publish together; an event does not wait for a related world visual omitted by state priority. A picked-up ground item may therefore remain visible briefly after the inventory update. The server still owns whether that item exists and whether another pickup is allowed.
3. **Refusals are events.** A refused intent comes back as an event that names the intent's sequence number and a reason enum. It is not an error in the transport sense.

### 5. Reconnect

An authenticated connect token lets a client resume its session on the same shard. Each new connection uses a fresh token nonce and fresh traffic keys for the same account and session. It never resets a packet nonce counter under previously used keys.

Event acknowledgement means successful atomic application publication, not packet receipt. The client retains a stable stream identity and applied event sequence across a network reconnect. The server replays after that application cursor. Duplicate delivery attempts do not apply an event twice. This replaces `session` and `last_seq` in `welcome`.

On resume, retained events publish with the first certified current full-state reset and keep their producing ticks. A reset has an explicit baseline identity and a completion certificate covering all required parts. Timeout and ordinary priority scheduling do not certify a complete reset. Resume availability is bounded by declared retention time and byte limits. Exceeding either limit explicitly makes the session unavailable for resume. Exactly-once application after a client process loses its checkpoint requires persistence or an explicit new session; network reconnect alone does not provide that guarantee.

### 6. Moving between servers

1. The current shard sends a `transfer` event. It holds the new shard's address and a connect token for it.
2. The client connects to the new shard and keeps rendering the old world until the first full tick arrives.
3. Entity ids are scoped to a shard, so the client clears its world when the first tick from the new shard arrives.
4. How the old shard hands the player's data to the new shard is a server-to-server protocol. It is outside this ADR.

### 7. Recording and replay

1. The client core writes every packet it receives, after decryption, to a recording file with its receive time. The file header holds the schema hash.
2. The server can record each connection's outbound packets the same way.
3. Replay feeds a recording into the same core with a clock driven by the recorded times. The world state after replay must equal the state the original session had, byte for byte.

### 8. Testing

1. **Network simulator.** Both implementations ship a simulator that drops, delays, duplicates, and reorders packets from a fixed seed. Every transport test runs through it, so a failure replays from its seed.
2. **Fuzzing.** Every decoder runs under a fuzzer. The server uses Go's native fuzzer, and the client uses libFuzzer. Malformed input must never crash either side or get past the decoder.
3. **Conformance vectors.** `shared/wire/vectors/` holds encoded packets next to their expected decoded text. Both implementations must decode every vector to the same text, and encode the text back to the same bytes.
4. **Cross-implementation test.** A test runs the Go server and the C++ client over loopback through the simulator.

## Consequences

- The cut-over deletes `client/scripts/net_client.gd`, `server/internal/net/protocol.go`, and the WebSocket hub. They do not run next to the new stack afterwards.
- GDScript no longer sees wire messages. It reads the core's world tables and calls actions such as `attack(target)`.
- The server tick loop gains two new jobs. It tracks interest sets, and it keeps the last acknowledged tick for each client.
- The login service becomes a hard dependency for connecting. Until it exists, a development-only token issuer with a fixed key issues tokens. The development issuer is excluded unless explicitly enabled with the Go `devtoken` build tag or the CMake `MARQUE_DEV_ISSUER` option. The CMake option is off by default.

## Open questions

- Interest cell size and radius, and the per-client byte budget per tick remain open. [ARM-362](https://linear.app/arminas/issue/ARM-362/measure-crowds-to-settle-interest-radius-byte-budget-and-position) settles them with simulated crowds.
- Position precision and range for quantization remain open for ARM-362.
- Whether the client sends `input` at the 25 Hz tick rate or at its frame rate remains open for ARM-362.
- Token-key distribution, the server-to-server handoff for `transfer`, and the token expiry clock-skew allowance wait for the login service.
- [ARM-363](https://linear.app/arminas/issue/ARM-363/cut-over-the-client-and-server-and-delete-the-json-wire) settles the cut-over order.

## Non-goals

- Browser clients.
- Writing our own crypto primitives.
- Seeing across shard borders before a transfer.
- Compatibility between different schema versions.
