# Wire protocol

The single source of truth for what crosses the socket. Server and client are written by
different people who cannot talk to each other, so this file is the contract between them.
It beats any brief, any comment, and any memory. If code disagrees with this file, the code
is wrong.

Amend this file first, then change code. Never the reverse.

Status: M0. Sections marked **M2** are reserved and not implemented yet.

## Envelope

- Transport is WebSocket. Every frame is a **text** frame carrying exactly one JSON object.
- Every message object has **exactly one top-level key**, and that key names the message.
  `{"move_to":{"x":1.0,"z":2.0}}` is one message named `move_to`.
- Binary frames are a protocol error.

Key-as-tag rather than a `{"type":...}` discriminator, matching the convention in `CLAUDE.md`.
It decodes cleanly on both ends. In Go, unmarshal to `map[string]json.RawMessage`, assert one
key, switch, then unmarshal the body. In GDScript, take `keys()[0]` and match.

## Compatibility

These three rules are what let every later message land additively instead of as a lockstep
change across already-merged units. They exist because M1 and M2 will add messages to a client
that was written before those messages existed.

1. **An unknown top-level key is logged loudly and ignored.** It is not an error and it does
   not close the connection. This is the one place the project's fail-fast doctrine is
   deliberately relaxed, because the alternative is that adding a message breaks every older
   peer.
2. **An unknown field inside a known body is ignored.** Senders may add fields.
3. **A frame with zero or more than one top-level key is a protocol error.** Reply with
   `error` and close. This is not forward compatibility, it is a malformed frame.

## Clock

The tick counter is the clock. Nothing in game logic reads wall-clock time.

**Server.** `tick` is a counter starting at 0 at process start, incrementing once per
`tick_ms`. It never resets while the process lives. The tick loop uses an accumulator against
a monotonic clock and may run at most **5** catch-up ticks in one iteration; beyond that the
remainder is discarded and the drop is logged. Unbounded catch-up spirals under load.

**Client.** On `welcome`, record `anchor_tick = welcome.tick` and `anchor_time = <monotonic
now>`. Thereafter:

    estimated_tick = anchor_tick + floor((monotonic_now - anchor_time) / tick_ms)

**The client must never accumulate frame deltas to advance its tick estimate.** A minimized or
stalled window stops producing frames, and a frame-delta clock would then fall permanently
behind with nothing to correct it. Anchoring to a monotonic clock survives the pause.

The client's estimate necessarily lags the server by roughly one-way latency, so a freshly
arrived `path` can carry a `start_tick` in the client's perceived future. **Elapsed time since
`start_tick` is clamped at zero**; a negative elapsed means "has not started yet", not
"rewind".

**M2.** A periodic `{"tick":{"t":N}}` heartbeat for drift correction and liveness. Reserved,
not sent in M0. Rule 1 above is what makes adding it free.

## Coordinates

Ground-plane `(x, z)` floats in Godot world units, `y` up. **`y` never appears on the wire.**
The world is 3D but movement is not. `y` is whatever the ground is at that point and is the
client's business. See the Movement section of `NOTES.md`.

World bounds are `x, z ∈ [-128.0, 128.0]`. One named constant on the server. Revisitable once
there is map content; it is a placeholder chosen to be finite, not chosen to be right.

## Messages, client to server

The client sends intents and never facts. It has zero authority.

### `move_to`

    {"move_to":{"x":42.3,"z":17.8}}

A request to walk to a point. The server decides whether it is legal and what path results.

**M2.** Any client-to-server body may carry an integer `seq`. Servers before M2 ignore it per
compatibility rule 2. Reserved now so that M2's dedupe fills in a field rather than
renegotiating every intent's contract.

## Messages, server to client

### `welcome`

    {"welcome":{"you":1,"tick_ms":150,"tick":142,
                "players":[{"id":1,"x":0.0,"z":0.0},{"id":2,"x":5.0,"z":5.0}]}}

The first message on every connection. `you` is this client's own id. `players` is every player
in the world **including itself**, at its position as of `tick`.

Immediately after, the server sends one `path` per player currently mid-walk, so a joining
client learns in-flight movement through the same code path as live movement. There is no
separate snapshot format for paths.

**Replayed paths are re-anchored, not resent verbatim.** A replayed `path` carries
`start_tick` equal to the current tick, `points[0]` equal to that player's position right now,
and only the waypoints still ahead of them. A verbatim resend of a stale path would contradict
the position this same `welcome` reports in `players`, and the two would only agree if the
client's clock were already perfect.

### `spawn` / `despawn`

    {"spawn":{"id":2,"x":0.0,"z":0.0}}
    {"despawn":{"id":2}}

Broadcast to everyone **except** the joining or leaving player, who learns its own existence
from `welcome`.

### `path`

    {"path":{"id":1,"start_tick":142,"points":[[10.0,4.0],[42.3,17.8]],"speed":3.0}}

Broadcast to everyone **including** the mover. `points[0]` is always that player's position at
`start_tick`. `speed` is world units per second, constant across the whole polyline.

A `move_to` arriving mid-walk replaces the current path. The replacement's `points[0]` is the
player's interpolated position at the tick the intent is processed, not the previous path's
origin.

The server sends waypoints, never per-tick positions.

**Degenerate paths.** The server does not emit a path whose total length is below an epsilon.
Clicking the ground you are already standing on produces no `path` and one log line. The client
walker still treats a zero-length segment as instantly complete, because two defenses cost
nothing and a divide-by-zero-length produces a NaN position that is painful to trace.

### `error`

    {"error":{"re":"move_to","msg":"out of bounds"}}

Sent to the offending client only. `re` names the message being rejected, and is omitted when
the frame was too malformed to attribute. `msg` is for a human reading a log, not for display
and not for branching on.

Without this, a rejected intent is indistinguishable from packet loss or a stalled server, and
the client debugging that has to read server logs across a language boundary. It also matters
later: `NOTES.md` decides that unreachable clicks are rejected rather than snapped, so once a
real navmesh lands, rejection becomes routine rather than exceptional.

## Validation

The server validates every intent against its own state. It never trusts a client value.

- A coordinate outside world bounds is **rejected**, not clamped and not snapped to the nearest
  legal point. `NOTES.md` is explicit on this.
- JSON cannot carry `NaN` or `Infinity` as literals, so a decoder error covers those. The real
  hazard is a large **finite** float such as `1e30`, which decodes fine and then overflows
  32-bit vector math on the client. Bounds checking is what stops it. Check `IsNaN` and `IsInf`
  on the decoded value anyway; it is one line and it is a real invariant.
- A rejected intent produces one `error` to the sender, one log line, and **no broadcast**.

## Ordering and the join race

Getting this wrong produces a duplicated avatar or a client that never learns about a player,
and both look like client bugs.

**Server.**

1. Every frame to a connection goes through that connection's **single ordered send queue**.
   Nothing bypasses it, `welcome` included. Two paths to one socket have no ordering guarantee
   between them and can interleave mid-frame.
2. Nothing is sent to a connection before its `welcome`.
3. `welcome` and its path replays are composed and enqueued as **one atomic step** inside the
   state-owning goroutine. Any broadcast enqueued after that step includes the new client.
4. A connection whose send queue is full is closed. It is never waited on. The tick loop must
   not be blocked by a slow client.

**Client.** Appliers are idempotent, because a redundant message is cheaper to tolerate than to
prevent.

- `spawn` for an id already known **replaces** rather than adding a second avatar.
- `despawn` for an unknown id logs and ignores.
- `path` for an unknown id logs and ignores.

## Identity

Player ids are integers assigned sequentially from 1 as connections arrive. They are
connection-scoped, are never reused within a process lifetime, and carry no meaning across a
restart. `welcome` reissues `you` on every connection, so nothing may assume an id is stable.

There is no connection limit in M0.

**M2.** Reconnect requires mapping a connection to a durable identity before per-identity
sequence dedupe means anything. That mapping does not exist yet and M0 must not pretend it does.

## Deliberately absent

Named so nobody adds them thinking they were forgotten.

- No authentication. Ids are sequential and unverified.
- No sequence numbers or acks. **M2.**
- No heartbeat. **M2.**
- No items, inventory, or interaction intents. **M1.**
- No camera, facing, or view direction, ever. The camera is pure client presentation and the
  server does not know it exists.
- No per-tick position broadcasts. Waypoints only.
- No interest management. Everything broadcasts to everyone.
