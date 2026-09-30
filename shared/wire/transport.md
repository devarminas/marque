# Transport

This is the byte-level specification of the reliable-UDP transport in ADR 0018 section 1. The Go implementation is `server/internal/transport`. The C++ client core implements the same rules. The vectors in `vectors/transport/` hold both to this document, and the last section defines their format.

The transport knows nothing about the schema. It moves schema messages as opaque byte strings. The only schema fact it carries is the 64-bit schema hash in every header.

## Conventions

- Integers are little-endian and fixed width unless the field says "length".
- A length is 1 or 2 bytes. A value below 128 is one byte. A value from 128 to 16383 is two bytes, `v & 0x7f | 0x80` then `v >> 7`, and the second byte must be 1 to 127. A length is always at least 1. Every length in this protocol fits in two bytes.
- Sequence numbers and reliable message ids are `u16` and wrap from 65535 to 0. `a - b` on them means `(a - b) mod 65536`.
- Time is a `u64` count of microseconds from a clock the caller supplies. The core never reads a clock itself. See "Time" for what the caller must guarantee.
- "Peer" means the other side of the connection. A connection has a role, `server` or `client`.

## Time

Every operation that takes `now` reads one clock per side. The caller keeps `now` non-decreasing across successive `flush` calls. The `now` that goes with a received datagram may lag behind the latest `flush` time: the server stamps it on the reader goroutine, and the tick loop may apply it after a `flush` that read the clock later.

The core tolerates that lag with two rules:

- Elapsed time saturates at zero. Wherever this document writes `now - last_x` for a time `last_x` (`last_receive`, `last_send`, a fragment's `last_sent`), it means `now - last_x` when `now >= last_x`, and `0` otherwise.
- `last_receive` never moves backwards. Accepting a datagram at `now` sets `last_receive = max(last_receive, now)`.

## Constants

| Name | Value | Meaning |
|---|---|---|
| `ProtocolID` | `0x3151524d` (bytes `4d 52 51 31`, "MRQ1") | First field of every header. |
| `MaxDatagram` | 1200 | Largest datagram, seal overhead included. |
| `HeaderSize` | 20 | Bytes before the first section. |
| `FragmentSize` | 1024 | Bytes of message data per full fragment. |
| `MaxFragments` | 64 | Most fragments in one reliable message. |
| `MaxMessage` | 65536 | Largest reliable message, `FragmentSize * MaxFragments`. |
| `WindowMessages` | 256 | Most reliable messages in flight, counted from the oldest unacked. |
| `WindowBytes` | 65536 | Most reliable message bytes in flight, and most bytes a receiver buffers. |
| `AckBits` | 32 | Width of the ack bit field. |
| `KeepaliveAfter` | 100000 (100 ms) | Silence before a keepalive. |
| `TimeoutAfter` | 5000000 (5 s) | Silence before a timeout. |

Both peers must use these values. The local parameters are in the last table.

## Channels

Four channels exist. Their numbers are the `codec.Channel` values in `server/internal/wire/codec`.

| Number | Channel | Sent by | Kind |
|---|---|---|---|
| 1 | `state` | server | unreliable |
| 2 | `events` | server | reliable, ordered |
| 3 | `input` | client | unreliable |
| 4 | `intents` | client | reliable, ordered |

Each role sends one unreliable channel and one reliable channel, and receives the other two. The unreliable channel of a role always has the lower number.

## Datagram layout

A datagram is a header, then at most one unreliable section, then at most one reliable section. The sections appear in that order. The body is everything after the header. Sealing (see "Seal seam") transforms only the body.

### Header

| Offset | Type | Field |
|---|---|---|
| 0 | `u32` | `ProtocolID` |
| 4 | `u64` | schema hash (`wire.SchemaHash`, `marque::wire::schema_hash`) |
| 12 | `u16` | sequence of this datagram |
| 14 | `u16` | ack: the newest sequence received from the peer |
| 16 | `u32` | ack bits: bit `i` set means sequence `ack - 1 - i` was received |

Before a side has received anything, it sends ack `0xffff` and ack bits `0`. Each side numbers its datagrams from 0, one per datagram, keepalives included.

### Unreliable section

| Type | Field |
|---|---|
| `u8` | channel number of the sender's unreliable channel (1 from a server, 3 from a client) |
| `u32` | stamp: the tick for `state`, the input sequence for `input` |
| `u16` | item count, at least 1 |
| items | per item: length, then that many bytes. Each item is one schema message. |

### Reliable section

| Type | Field |
|---|---|
| `u8` | channel number of the sender's reliable channel (2 from a server, 4 from a client) |
| `u16` | entry count, at least 1 |
| entries | per entry, the fields below |

Each entry is one fragment of one reliable message:

| Type | Field |
|---|---|
| `u16` | message id |
| `u8` | fragment index |
| `u8` | fragment count, 1 to `MaxFragments` |
| length + bytes | fragment data |

The index is below the count. A fragment whose index is below `count - 1` carries exactly `FragmentSize` bytes. The last fragment carries 1 to `FragmentSize` bytes. A message of `n` bytes has `ceil(n / FragmentSize)` fragments. Fragment `i` holds bytes `i * FragmentSize` up to `min((i + 1) * FragmentSize, n)`. A message of up to 1024 bytes is one entry with count 1.

### A keepalive

A keepalive is a header with no body. It is 20 bytes.

### Worked example

A server with schema hash `0x0123456789abcdef` that has received nothing queues the event `04 07 09 06` and flushes at 40000 µs with state stamp 1 and one item `03 01 02`. It emits one 43-byte datagram (`TestSpecExample`):

```
4d525131          protocol id
efcdab8967452301  schema hash
0000              sequence 0
ffff              ack: nothing received
00000000          ack bits
01                state section
01000000          stamp 1
0100              1 item
03 030102         length 3, item
02                events section
0100              1 entry
0000              message id 0
00                fragment index 0
01                fragment count 1
04 04070906       length 4, data
```

## Receiving a datagram

A receiver applies a datagram whole or not at all. It checks these conditions in order. The first failure refuses the datagram with the named error, and nothing changes except a counter.

1. The length is from `HeaderSize + seal overhead` to `MaxDatagram`. Otherwise `malformed`.
2. The protocol id is `ProtocolID` and the schema hash is its own. Otherwise `foreign`.
3. The seal opens the body. Otherwise `malformed`.
4. The body parses. Otherwise `malformed`. A body parses when it is exactly: an optional unreliable section on the peer's unreliable channel, then an optional reliable section on the peer's reliable channel, with nothing after. A section for any other channel, a count of 0, a length of 0, a non-canonical length, a truncated field, a fragment rule broken, or a trailing byte fails the parse.
5. The sequence is new (next section). Otherwise `duplicate` or `too_old`.

Then it commits, in this order: the sequence window, the unreliable section, the reliable entries in datagram order, and delivery.

### Sequence window

The receiver keeps `latest`, `bits`, and whether it has received anything. It starts with `latest = 0xffff`, `bits = 0`, and nothing received. For a datagram with sequence `s`:

- If nothing was received yet, accept it. Set `latest = s` and `bits = 0`.
- Let `ahead = s - latest`. If `ahead == 0`, refuse it as `duplicate`.
- If `1 <= ahead < 32768`, `s` is newer. Accept it. The new bits are `bits << ahead | 1 << (ahead - 1)` when `ahead < 32`, `1 << 31` when `ahead == 32`, and `0` when `ahead > 32`. Set `latest = s`. Implement the shifts with these three cases, since shifting a 32-bit value by 32 or more is undefined in C++.
- Otherwise `s` is older. Let `behind = latest - s`. If `behind > 32`, refuse it as `too_old`. If bit `behind - 1` is set, refuse it as `duplicate`. Otherwise set that bit and accept it.

The header's ack and ack bits are this window. Because the window only accepts sequences it can acknowledge, every accepted datagram is acknowledged in the next 33 datagrams the receiver sends.

### Unreliable staleness

The receiver keeps the newest stamp it has delivered, and starts with none. An unreliable section is delivered only when no stamp was delivered yet or its stamp is greater than the newest. Otherwise it is stale and dropped. The datagram is still accepted, and its reliable entries still apply. A delivered section hands up its stamp and all its items, in order.

Stamps are compared as plain `u32`. At 25 Hz they do not wrap for more than five years.

### Reliable reassembly

The receiver keeps `next`, the id of the next message to deliver, starting at 0. It buffers fragments of messages at or after `next`, and counts the buffered data bytes. For each entry, in datagram order:

1. If `id - next >= WindowMessages`, ignore it. It is a message already delivered.
2. If fragments of this id are buffered with a different fragment count, ignore the entry.
3. If this fragment index is already buffered, ignore the entry.
4. If buffering the data would take the buffered bytes past `WindowBytes`, ignore the entry.
5. Otherwise buffer it.

After all entries, while every fragment of message `next` is buffered: join its fragments in index order, deliver the result, forget it, subtract its bytes, and add 1 to `next`.

A sender that follows this document never triggers rules 2 and 4 and never sends an id `WindowMessages` or more ahead of `next`. An entry that does is ignored, not refused, because the datagram is already acknowledged by the window. Only the peer that sent it loses anything.

## Sending

### Reliable queue

`send(msg)` appends one reliable message to the queue. It refuses a message of 0 bytes or more than `MaxMessage` bytes with `message`, and refuses any message on a closed connection with `closed`. Ids go up by 1 from 0 in queue order. Each fragment has three facts: acked, sent, and the time it was last sent.

The queue holds every message that is not yet fully acked. Its first message is the oldest unacked one. Its length is the backlog. If a send makes the backlog greater than `BacklogLimit`, the connection closes as `slow_client`. The message is never dropped before that.

### Window and due fragments

A message at queue position `i` (0 is the oldest) is inside the window when `i < WindowMessages` and the byte sum of messages 0 to `i` is at most `WindowBytes`. The first message outside the window ends the scan, and every later message waits.

A fragment of a message inside the window is due at time `now` when it is not acked and either it was never sent or `now - last_sent >= ResendAfter`. The due list is every due fragment, oldest message first, lower index first within a message.

### Acks

When the receiver accepts a datagram, the sender takes the header's ack and ack bits. It treats sequence `ack` as acked, and `ack - 1 - i` for every set bit `i`. The sender remembers the fragment list of each datagram it sent in a ring of 256 slots, indexed by `sequence mod 256`. For each acked sequence whose slot holds that sequence and is not yet acked, it marks the slot acked and marks each listed fragment acked, if the message is still in the queue. Then it removes fully acked messages from the front of the queue.

The sender also takes the receiver's current window to put in the headers it writes, and sets `last_receive = max(last_receive, now)`.

### Flush

`flush(now, unreliable)` builds the datagrams for one tick. `unreliable` is a stamp and a list of items in priority order, and may be empty. The caller calls `flush` once per tick. The steps are:

1. If `now - last_receive >= TimeoutAfter`, the connection closes as `timed_out`.
2. If the connection is closed, emit nothing and report the state.
3. Pack due fragments, then unreliable items, under the budget (next section).
4. If nothing was packed and `now - last_send >= KeepaliveAfter`, emit one keepalive.
5. Give each datagram the next sequence, in packing order, and the current ack window. Record its fragments in the ring. Mark each packed fragment sent at `now`. If any datagram went out, set `last_send = now`.

A new connection starts with `last_send` and `last_receive` equal to the time it was created.

### Budget algorithm

`left` starts at `TickBudget`. A datagram's size counts its header, its seal overhead, and its sections. `empty` is `HeaderSize + seal overhead`. The current datagram has a size and a capacity. Opening a datagram closes the current one, subtracts its size from `left`, and starts a new one with size `empty` and capacity `min(MaxDatagram, left)`.

`room` is the capacity a new datagram would get: `min(MaxDatagram, left)` when there is no current datagram, else `min(MaxDatagram, left - current.size)`.

An entry costs `4 + length size + data size`. The first entry in a datagram also costs 3 for the reliable section header. For each due fragment, in order:

1. If there is a current datagram and the entry fits in its capacity, add it.
2. Otherwise, if `empty + 3 + entry cost > room`, stop packing fragments. They stay due for the next flush.
3. Otherwise open a datagram and add the entry.

Then, if there are unreliable items, count how many leading items fit in two places. Items cost `length size + item size`, and the section costs 7 more.

- `in_current`: in the current datagram's remaining capacity, or 0 if there is none.
- `in_new`: in `room - empty`.

If `in_current >= in_new` and `in_current > 0`, put `in_current` items in the current datagram. Otherwise, if `in_new > 0`, open a datagram and put `in_new` items in it. Otherwise send no items. Items after the first one that does not fit are not sent, even if a later one would fit. `flush` reports how many items were sent, so the caller can raise the priority of what it skipped.

Reliable fragments are never dropped. They only wait. Only `state` or `input` items are trimmed. `TickBudget` must be at least `MaxDatagram`, so a flush can always send one full fragment.

### Timeout and slow_client

A connection has one of three states: `open`, `timed_out`, or `slow_client`. It leaves `open` at most once. A closed connection emits nothing, refuses `send` and received datagrams with `closed`, and reports its state from every flush. No datagram tells the peer. The peer times out.

## Seal seam

A seal has an overhead and two operations. `seal(header, body)` returns the sealed body. `open(header, sealed)` returns the body or fails. The 20-byte header is sent in the clear and is the associated data. Packing reserves the overhead inside `MaxDatagram`. Until the handshake exists (ARM-354), the seal is the identity with overhead 0.

A connection starts established. The handshake creates it after the handshake completes.

## Server threading

The server splits each connection into two halves that share no memory (ADR 0018 section 1.9).

- The socket reader goroutine owns the receive half, `Receiver`: the sequence window, the staleness rule, and reassembly. It decodes each delivered `input` item and `intents` message with the channel's schema decoder and sends one `Inbound` value per accepted datagram over a channel. A decode failure is a fault. The reader forgets the peer and the tick loop drops it.
- The tick loop owns the send half, `Sender`. It calls `Observe(peer_ack, own_ack, at)` with each `Inbound`, `Send` for events, and `Flush` once per tick.

The client core may keep both halves in one object (`Endpoint`).

## Conformance vectors

Each file in `vectors/transport/*.vec` is a script for one connection. `go test ./internal/transport -run TestVectors -update` (from `server/`) regenerates them from the scenarios in `scenarios_test.go`. `TestVectors` fails when a file is stale and replays every file.

A file is UTF-8 text, one line per record. Blank lines and lines starting with `#` are comments. A line starting with `> ` is an expected output of the op above it. Any other line is an op. Tokens are separated by one space. Byte strings are lowercase hex. Numbers are decimal, except the schema hash.

A runner runs each op, collects its outputs in order, and compares them with the expected lines up to the next op. The two lists must match exactly.

| Op | Action | Outputs, in order |
|---|---|---|
| `endpoint <role> <hash> <budget> <backlog> <resend> <now>` | Create the connection. `role` is `server` or `client`. `hash` is 16 hex digits. The seal is the identity. | none |
| `send <hex>` | `send` one reliable message. | `error <name>` if refused |
| `flush <now>` or `flush <now> <stamp> <hex>...` | `flush`, with the unreliable items if given. | `datagram <hex>` per datagram; `unreliable_sent <n>` if items were given; `state <timed_out\|slow_client>` if closed |
| `recv <now> <hex>` | Receive one datagram. | `error <name>` if refused, and nothing else; otherwise `stale` if the section was stale, `unreliable <stamp> <hex>...` if one was delivered, then `reliable <hex>` per delivered message |

The error names are `malformed`, `foreign`, `duplicate`, `too_old`, `closed`, and `message`.

The files are:

| File | Covers |
|---|---|
| `client_basic.vec` | A client's receive, send, and keepalive. |
| `server_basic.vec` | A server and a live client for three ticks. |
| `fragmentation.vec` | Three- and two-fragment messages out of order, with a duplicate. |
| `resend.vec` | A lost fragment is resent after `ResendAfter` and stops once acked. |
| `budget.vec` | Events deferred and state trimmed under a 2400-byte budget. |
| `stale.vec` | Stale state dropped while its datagram's events still deliver. |
| `sequence_wrap.vec` | The window across 65535 to 0, duplicates, and the 32-behind edge. |
| `malformed.vec` | Every parse failure, and that none consumes a sequence. |
| `hostile_reliable.vec` | The ignore rules of reassembly. |
| `slow_client.vec` | The backlog limit and the closed state. |
| `timeout.vec` | Keepalive timing and the timeout edge. |

## Local parameters

Each side picks these for itself. The defaults are unmeasured. ARM-362 measures them.

| Parameter | Default | Meaning |
|---|---|---|
| `TickBudget` | 4800 bytes | Most bytes one flush emits, keepalives aside. At least `MaxDatagram`. |
| `BacklogLimit` | 1024 messages | Most reliable messages queued and unacked before `slow_client`. |
| `ResendAfter` | 200000 µs (200 ms) | Wait before an unacked fragment is due again. |
