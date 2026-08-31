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

**Rules 1 to 3 are written from the server's side. The client's side is not symmetric.** The
server may close on a bad frame because a misbehaving client is one of many and costs nothing.
A client cannot close on a bad frame from the server, because the server is its only peer,
`error` is server-to-client only so it has nothing to reply with, and M0 has no reconnect, so
one malformed frame would cost the player the whole session.

**A client logs loudly and drops the single offending frame, keeping the connection.** That
applies to a frame that is not valid JSON, is not an object, carries zero or several top-level
keys, or is a known message whose body will not parse. Unknown top-level keys still follow
rule 1 and are ordinary forward compatibility, not errors.

This is deliberately a different rule from the server's, and it is the one place in this file
where the two ends of the socket are told to do opposite things. Revisit it when M2 adds
reconnect, because a client that can cheaply recover has the option of being stricter.

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

**`points` always has at least one element. A one-element path means "halt here".** The walker
holds at the final point of a polyline, so a polyline of one point is a complete, valid
instruction to stand still at that point. No separate `stop` message exists or is needed.

**Degenerate clicks**, meaning a click that resolves to within an epsilon of the player's
current position, split by whether the player is moving:

- **Stationary.** Nothing changes, so no `path` is broadcast. The clicking client receives
  `{"error":{"re":"move_to","msg":"already there"}}` and the server logs one line. Without that
  reply the click is indistinguishable from a dropped frame, which is exactly the confusion the
  `error` message exists to remove.
- **Walking.** A one-element halt path at the player's current interpolated position,
  broadcast to everyone as any other path is. **It carries the player's own position, not the
  clicked point.** Those differ by up to the epsilon, and `points[0]` is the position at
  `start_tick` exactly rather than approximately. A client that draws a click marker at the
  clicked point and the avatar at `points[0]` will see them disagree by that much, correctly.

**A halted player is not mid-walk**, so a late joiner receives no path replay for them. They
appear only as a position in `welcome.players`. A client that creates an avatar's walker lazily
on the first `path` handles this correctly by accident. A client that expects one `path` per
listed player will wait forever for one that is never coming.

This is what makes "stop walking" representable. It costs a carve-out now and would otherwise
be discovered in M1, where "you were interrupted" and "the item is gone, stop walking" both
need it, after a client walker had already been built assuming paths always run to completion.

The client walker still treats a zero-length segment as instantly complete, because two
defenses cost nothing and a divide by zero length produces a NaN position that is painful to
trace.

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

**Three ways a slow client dies, and which one wins is undeclared.** A send queue that fills
reports one reason. A write that blocks past the write timeout reports another. And when that
timed-out write tears the connection down, the read pump can reach the close first and report
a third, a read error, for what was actually a slow client.

Which one you get depends on the send rate into a jammed socket, not on anything the code or
this file states. Measured against a real stalled peer: sustained traffic above roughly
thirteen frames per second fills the 64-slot queue inside the write timeout's window, so the
queue wins. Below that the timeout wins, and it can surface as a read error. **M0's ordinary
traffic is the slow case**, because M0 has no per-tick broadcasts and no heartbeat, so a
stalled client jams nothing for minutes and then dies by timeout. The queue branch is reached
in the test suite only by a deliberate flood of oversized frames.

**Decide which reason is authoritative before M1 adds its first new message.** This is a
semantics decision rather than a code change, it is cheap now, and it is expensive once
anything branches on the reason string. Nothing in M0 does, which is the only reason this is
not urgent.

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

## Decoding notes for the Godot side

Reported by the writer of the Go server, which had to produce all of this. Each one is a place
a GDScript client will get it subtly wrong.

- **`JSON.parse_string` returns every JSON number as a `float`.** `welcome.tick` and
  `path.start_tick` are 64-bit integers on the wire and arrive as floats. Convert with `int(...)`
  before comparing. No precision is lost, since a float64 holds tick counts exactly for far
  longer than this project will run, but a GDScript `==` against an int will bite someone.
- **Coordinates have two encodings, deliberately.** `welcome.players[]` and `spawn` use
  `{"id":..,"x":..,"z":..}` because they carry an id. `path.points` uses `[[x,z],...]` because
  an array is materially smaller for a polyline. So a client writes `Vector2(d.x, d.z)` in one
  place and `Vector2(p[0], p[1])` in the other for the same idea. This is a real cost, accepted
  knowingly; it is written here so the second one gets written correctly.
- **`error.re` is absent rather than null when the frame could not be attributed.** Use
  `d.get("re", "")`. A malformed frame yields `{"error":{"msg":"text frames only"}}` with no
  `re` key at all.
- **`x` and `z` are ground-plane world coordinates.** When they land in a `Vector2`, the
  `Vector2.y` component holds world **Z**. This has caught people already.

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
