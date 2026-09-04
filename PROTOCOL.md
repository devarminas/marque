# Wire protocol

The single source of truth for what crosses the socket. Server and client are written by
different people who cannot talk to each other, so this file is the contract between them.
It beats any brief, any comment, and any memory. If code disagrees with this file, the code
is wrong.

Amend this file first, then change code. Never the reverse.

Status: **M0 and M1 shipped.** Everything marked **M1** is implemented and on the wire, so a
reader looking at today's code will find all of it. **M2 is in progress.** Each **M2** marker
names the unit that discharges it. A marker reading plain **M2** is still reserved and nobody is
writing it. A marker naming a unit and marked *shipped* is implemented and on the wire, exactly
as an **M1** marker is. A marker naming a unit without that mark is somebody's live contract.

**M2a**, **M2b** and **M2c** are shipped. The three-way form above replaces a sentence that listed
the live units by name, which put every later unit in the position of editing a status line that
was about somebody else.

This line used to say M1's messages were specified and not yet implemented, and it stayed wrong
for the whole of M1 because correcting it was never any unit's job. It is a status line; being
stale is the only way it can fail.

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

**M2d.** A periodic `{"tick":{"t":N}}` heartbeat for drift correction and liveness. Reserved,
not sent in M0 or M1. Rule 1 above is what makes adding it free.

**The client's half of it is specified below and is implemented (M2c).** Until M2d lands no
server emits `tick` at all, which is why every rule below has to keep working against a server
that never sends one.

### Receiving `tick`. **M2c.**

The client compares `t` against its own `estimated_tick()` **at receipt**, and:

- **`t` differs from the estimate.** Re-anchor the clock at `t` — the same `anchor(t, tick_ms)`
  call `welcome` makes, so a heartbeat, a reconnect and a join correct the clock through one
  code path — and log the signed delta on one line:

      session: clock corrected by %+d tick(s) at heartbeat %d

  The delta is signed because its sign is the diagnosis: a client running ahead of the server
  and one running behind it are different faults, and an unsigned magnitude names neither.
- **`t` equals the estimate.** Do nothing, and log nothing. Agreement is the ordinary case once
  the clock is right, so a line per heartbeat would bury the corrections this log exists for.
- **`tick` before `welcome`.** Logged and ignored. There is no `tick_ms` to anchor with, and
  nothing reaches a connection before its `welcome` (*Ordering and the join race*), so this is
  defence against a broken peer rather than a flow.
- **`tick` with no numeric `t`, or a negative `t`.** Dropped with a loud log, connection kept,
  exactly as any other unparseable body is (*Compatibility*). Ticks start at 0 and only ever
  increase, so a negative one is not a clock reading and must not reach the anchor: the client's
  clock refuses it, and a receiver that passed it on anyway would log a correction it did not
  make.

**A correction is felt, not merely logged.** Every mid-walk body derives its position from the
clock, so re-anchoring forward by N ticks advances every walker by `N * tick_ms * speed` along
its polyline in the frame the heartbeat lands. Measured on the Godot client: a `+10` re-anchor
at 150 ms and 1.0 u/s jumped a walking body 1.5 units. Re-anchoring *behind* a path's
`start_tick` puts the body back at `points[0]` rather than rewinding past it, which is the
clamp-at-zero rule above holding. This is the cost of a correction and the reason a heartbeat
interval is a tuning decision rather than a free one.

### Liveness. **M2c.**

`welcome` may carry an integer `heartbeat_ticks`: the interval, in ticks, at which the server
intends to send `tick`. **Absent, zero, or unreadable means liveness is off.**

Off has to be the default, because it is what every server before M2d says. A client that
defaulted the field to anything else would abandon every session it opened against one, on a
timer, which looks exactly like a network fault. A `heartbeat_ticks` that is present but
negative or not a number is logged and read as zero rather than dropping the whole `welcome`:
that is the same call this file already makes for `welcome.items` being `null`, and for the same
reason — the cost of strictness there is that the client never joins and sits frozen forever.

With `heartbeat_ticks > 0`, the client abandons the socket once no `tick` has arrived for

    3 * heartbeat_ticks * tick_ms

milliseconds, measured from the **last tick-bearing frame**. `welcome` counts as one, so the
window opens at the join rather than at the first heartbeat, and a server that promises
heartbeats and then sends none is caught. Three intervals rather than one, so that a single
lost or late heartbeat is not a disconnect. The client logs loudly first.

**The window is a lower bound.** A client tests its deadline at whatever rate it polls, so it
abandons at some point at or after the window and never before it. Three intervals is chosen to
be wide enough that this granularity — and a heartbeat that arrives in the same breath as the
deadline expiring — cannot decide the outcome.

**The window closes with the connection and does not reopen.** A `tick` arriving after the
socket has gone re-arms nothing: there is no longer anything that could send the next one, and a
timer waiting on a dead connection would report a second death for the first one.

**Abandoning is not closing, and the difference is the whole point.** The client drops the
transport without sending a close frame. A close frame is a logout, and a socket that went
silent is not a logout: the server must see a read error and record `peer_gone`, which is the
suspending case, rather than `closed`. A client that closed politely here would tell the server
its player had quit, which is precisely the state it is trying not to lose.

The client does not reconnect afterwards. That is M2f.

## Coordinates

Ground-plane `(x, z)` floats in Godot world units, `y` up. **`y` never appears on the wire.**
The world is 3D but movement is not. `y` is whatever the ground is at that point and is the
client's business. See the Movement section of `NOTES.md`.

World bounds are `x, z ∈ [-128.0, 128.0]`. One named constant on the server. Revisitable once
there is map content; it is a placeholder chosen to be finite, not chosen to be right.

## Messages, client to server

The client sends intents and never facts. It has zero authority.

### Sequence numbers. **M2b**, shipped.

**Any client-to-server body may carry `seq`, an integer of at least 1.**

    {"move_to":{"x":42.3,"z":17.8,"seq":5}}
    {"pickup":{"item":7,"seq":6}}
    {"drop":{"slot":3,"seq":7}}

It is specified here, once, rather than in each message below, and it is **parsed once at the
envelope**, in the same step that reads the single top-level key. No message body declares it and
no message body may give it a different meaning. This paragraph used to sit inside `move_to`
because that is where M1 happened to reserve it, which read as though `seq` were one message's
field.

The server keeps one number per player, `last_seq`, and it is a **high-water mark** rather than a
set of the numbers it has seen.

- **Absent is unsequenced**, applied exactly as it was before this unit. Every client built
  before **M2e** sends no `seq` and is exactly as correct as it was.
- **A `seq` at or below `last_seq` is a duplicate.** It is not applied, and **it is not
  answered**. The server logs `intent_duplicate` with `player`, `re`, `seq` and `last_seq`, and
  sends nothing at all.
- **A `seq` above `last_seq` is applied, and `last_seq` becomes `seq`**, even when the intent is
  then refused. A refused intent was received and decided, and its retry would be refused for the
  same reason, so consuming the number costs nothing.
- **Gaps are accepted.** `seq` 3 followed by `seq` 10 applies both and leaves `last_seq` at 10. A
  high-water mark cannot express "4 through 9 are still coming", and nothing here needs it to,
  because the client is the only thing that knows what it skipped.
- **A `seq` that is 0, negative, fractional, or not a number is a `malformed_json` refusal**
  carrying `re`, and the connection is kept. Zero is refused rather than read as absent: a client
  that computed a sequence number and got zero has a bug, and the server should name it rather
  than quietly downgrade the frame to unsequenced. `5.0` and `1e2` are refused too, for a reason
  that is about the literal rather than the value; the *Decoding notes* say what a client must do
  about it.
- **`"seq":null` reads as absent**, and is the one leniency here. It costs nothing, it is what a
  serialiser emitting an unset optional produces, and there is no second meaning it could have.
- **`last_seq` is per player, not per connection.** It is 0 at a fresh join, it survives
  suspension and resume because the player does (see *When the connection dies*), and it dies
  with the player.
- **`move_to`, `pickup` and `drop` log events carry `seq` when the frame did**, and omit the
  field when it did not. That is what lets a reader of the event log tell a first application
  from a retry without joining two lines together.

**A `seq` the envelope accepted is consumed even when the body is then refused.** A frame whose
`seq` parses and whose body does not, `{"move_to":{"x":1,"seq":5}}`, is refused for the missing
`z` and still leaves `last_seq` at 5. The alternative makes `last_seq` depend on whether the
server liked the body, and `last_seq` is the only thing that tells a client where its numbering
stands. A number the client cannot predict from what it sent is not a restatement of anything.
The cost is narrow and worth naming: a client that reuses one `seq` for a corrected body has the
correction deduped. That is a client sending two different intents under one number, which this
protocol has never let mean anything.

**There are no acks, and that is a decision rather than an omission.** `welcome.last_seq` is a
cumulative restatement of where the player's numbering stands, in the same doctrine as
`inventory` and as `welcome` itself, and a restatement cannot drift. A per-intent ack would be
one frame per intent carrying something the client can already derive, and the only client that
needs more is one that replays unacknowledged intents. No client does. **Revisitable the first
time one does.**

That is also why a duplicate is answered with nothing. An `error` naming the duplicate would be
an ack wearing a different hat, and it would teach clients to branch on it. A client learns the
truth from the `welcome` and `inventory` restatements it is already sent, never from an answer to
a retry.

### `move_to`

    {"move_to":{"x":42.3,"z":17.8}}

A request to walk to a point. The server decides whether it is legal and what path results.

### `pickup`. **M1**

    {"pickup":{"item":7}}

A request to take a ground item. `item` is an item id, which is **not** a player id; see
*Entity naming*. Semantics are in *Items and inventory*.

### `drop`. **M1**

    {"drop":{"slot":3}}

A request to drop whatever is in that inventory slot at the player's feet. `slot` is an index,
not an item id: the client names a position in its own cached inventory and the server looks up
what is actually there. That is the intents-never-facts rule at its most load-bearing, because
a client that could name the item id could name one it does not own.

## Messages, server to client

### `welcome`

    {"welcome":{"you":1,"tick_ms":150,"tick":142,
                "players":[{"id":1,"x":0.0,"z":0.0},{"id":2,"x":5.0,"z":5.0}]}}

The first message on every connection. `you` is this client's own id. `players` is every player
in the world **including itself**, at its position as of `tick`.

**M2a** adds `session`, this player's durable identity:

    {"welcome":{"you":1,"session":"9f2c1ab7d0e4485fa6c3b81d27e05934",
                "tick_ms":150,"tick":142,
                "players":[{"id":1,"x":0.0,"z":0.0}],
                "items":[]}}

It is a sibling of `you` rather than of `players`, for the reason `items` is a sibling of
`players` and `inventory` is not: `you` and `session` are the two things this message says about
the receiving client, and everything else in it is the world. See *Identity* for what a client
does with it. A pre-M2 client ignores the field under compatibility rule 2 and is exactly as
correct as it was before, because a client that never sends a token never resumes.

**M2b** adds `last_seq`, the highest sequence number this server has accepted from this player:

    {"welcome":{"you":1,"session":"9f2c1ab7d0e4485fa6c3b81d27e05934","last_seq":7,
                "tick_ms":150,"tick":142,
                "players":[{"id":1,"x":0.0,"z":0.0}],
                "items":[]}}

It is `0` at a fresh join and on every `welcome` to a player that has never sent a `seq`. The key
is always present; it is never omitted and never `null`. It rides in **every** `welcome`,
including a resumed one, and a resumed one is the whole point: it is where a reconnecting client
reads how far its numbering got before the socket died. There are no acks, so this is the only
thing that says so. See *Sequence numbers*.

It is a third sibling of `you` and `session` for their reason. Those three are what this message
says about the receiving client, and everything else in it is the world. A pre-M2 client ignores
it under compatibility rule 2 and is exactly as correct as it was before, because a client that
never sends a `seq` is never deduped.

**M1** adds a sibling array, `items`, listing every item lying on the ground as of the same
tick:

    {"welcome":{"you":1,"tick_ms":150,"tick":142,
                "players":[{"id":1,"x":0.0,"z":0.0}],
                "items":[{"id":7,"kind":"acorn","x":3.0,"z":-2.0}]}}

`items` is the world, so it belongs in `welcome` alongside `players`. **The joining player's own
inventory is not in `welcome`**; it is private to one player rather than part of the world, and
it arrives as a separate `inventory` message inside the same atomic step. A pre-M1 client
ignores the `items` field under compatibility rule 2 and is exactly as correct as it was before.

**A repeated `welcome` is a full restatement of the world, not a patch.** "First message on every
connection" constrains position and never constrained multiplicity. A client receiving a second
`welcome` frees every body, re-anchors its clock, and rebuilds from the list. That is the only
reading consistent with `welcome` being the whole world restated: anything the client believed
beforehand is stale by definition.

**M2a makes that true on the wire rather than hypothetical.** A resumed connection receives the
ordinary welcome step — the same `you`, the same `session`, the world as of now, the path
replays, then its `inventory` — and it is a second `welcome` for that player by construction. It
is one connection's first `welcome` and one player's second, and the rule above is written from
the player's side because that is the side that has stale beliefs to discard. This paragraph
used to end "the server sends exactly one today, so nothing depends on this yet"; something
depends on it now.

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

**A `path` for an unknown id is dropped with a loud log.** Under the ordering guarantees below,
a conforming server cannot produce this: `spawn` precedes any path for that player, `welcome`
and its replays are atomic, and paths never follow a `despawn`. So this clause is **defense
against a broken peer, not an expected flow**, and it is written down so nobody later "fixes"
it into lazily conjuring an avatar from a `path`. Doing that would invent a player the server
never announced. Closing instead would violate the client's never-close rule. Dropping is the
least wrong of three bad options for a case that should not occur.

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

### `item_spawn` / `item_despawn`. **M1**

    {"item_spawn":{"id":7,"kind":"acorn","x":3.0,"z":-2.0}}
    {"item_despawn":{"id":7}}

Broadcast to **everyone, including the player who caused it**. This is `path`'s rule, not
`spawn`'s. `spawn` excludes the joining player because that player learns of itself from
`welcome`; there is no equivalent here, and a dropper who did not receive `item_spawn` would
have to conjure the body from its own intent, which is the client inventing state the server
never announced.

`kind` is an item type name. M1 ships exactly one, `acorn`. **A client that does not know a
`kind` renders it magenta and keeps going** (`NOTES.md`, the palette), because a missing asset
must scream rather than render nothing, and because unknown kinds are how content is added
without a client release.

### `inventory`. **M1**

    {"inventory":{"size":28,"slots":[{"slot":1,"kind":"acorn"}]}}

Sent to **one player only**, never broadcast. A full restatement of that player's inventory, not
a patch, matching `welcome`'s doctrine for the same reason: a restatement cannot drift, and
twenty-eight slots is nothing on the wire.

`slots` lists **only occupied slots**, each carrying its own index. Empty slots are absent
rather than null. A sparse list is smaller, and it keeps both ends off the question of how their
JSON library represents a null inside an array, which is a question about someone else's code
that this contract does not need to answer.

**An empty list is `[]`, or for `welcome.items` an absent key. It is never `null`.** This binds
both ends and it is not a style preference.

A Go server holding `Items []ItemState` that was never appended to marshals `null`, not `[]`,
and it does so silently. A strict client reading `null` as "not an array" drops the whole frame,
and for `welcome` that means **the client never joins and sits frozen forever**. Nothing in
either half looks wrong while that happens: the server sent a conforming-looking frame and the
client obeyed its own never-close rule. Found by a verifier reading across the two halves before
either shipped, which is the only place it could have been found cheaply.

So, two rules that overlap on purpose:

- **A sender never emits `null` for a list.** Initialise the slice; do not rely on the marshaller.
- **A receiver treats `null` as an empty list**, and logs loudly. Not as an absent key: those
  differ for `inventory.slots`, where absent is malformed and stays a dropped frame, because
  `inventory` and `slots` were born in the same contract revision so no sender legitimately
  omits it. `welcome.items` may legitimately be absent, from a pre-M1 server. This is the
  client's lenient side again, and the reasoning is the same one that forbids it closing on a
  bad frame: the server is its only peer, so the cost of being strict is the whole session, and
  the cost of being lenient is a log line naming a server bug.

`size` is the number of slots the player has. Twenty-eight, which is RuneScape's, and one
server-side constant. Slot indices run `0` to `size - 1`. `size` is on the wire so the client
draws the grid it is told to draw rather than hardcoding a second copy of the number.

The first `inventory` is sent inside the atomic `welcome` step, after `welcome` and after the
path replays. Thereafter one is sent to a player whenever that player's inventory changes, and
never otherwise.

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

## Items and inventory. **M1**

### Entity naming, decided

**Every entity family gets its own message names and its own id space.** Items are named by
`item_spawn`, `item_despawn`, `welcome.items`, and `pickup.item`. There is no polymorphic
`entity` message, no `kind` or `type` discriminator bolted onto `spawn`, and no shared id space.

The compatibility rules above already chose this, and the argument is short enough to check.
Adding a discriminator field to `spawn` would be read by every pre-M1 client under rule 2,
*unknown fields inside a known body are ignored*, so an M0 client receiving an item would build
a **player avatar** for it: a blue capsule that walks, standing where an acorn should be. Adding
a new top-level key is read under rule 1, *unknown top-level keys are logged and ignored*, so
the same client correctly renders no item at all. One rule degrades into a wrong world, the
other into an incomplete one, and incomplete is the only acceptable failure for a client that
cannot be upgraded in lockstep.

The generic-entity refactor, one `entity_spawn` with a type tag and players migrated onto it,
buys M1 nothing and rewrites merged, verified code to get there. Not now. Revisit when a third
entity family arrives, because two is not yet a pattern.

**Item ids are integers assigned sequentially from 1 as items enter the world**, per process,
never reused within a process lifetime, and drawn from a **counter of their own**. Item 1 and
player 1 are different things, no message mixes the two spaces, and every field naming an id
says which space it is in. An id that means one thing in one message and another thing in the
next is the cheapest possible bug to write and one of the more expensive to find.

### Inventory

Twenty-eight slots, RuneScape's number, one server-side constant, sent to the client as
`inventory.size`. One item per slot. **Nothing stacks in M1**, which is RuneScape's default for
ordinary items and which keeps the slot the unit of every transaction.

**The server never trusts a client's picture of its own inventory.** `drop` names a slot index
and the server looks up what is in it. A client that named an item id could name one it does not
have.

### Pickup

**Clicking an item walks you to it and then takes it.** That is RuneScape's answer and it is
taken without further argument. The consequence worth stating is that a pickup is a *pending
action on the server*, not an instantaneous one, and that is the whole reason the M1 milestone
is a contest rather than a lookup.

- **`pickup` is `move_to` at the item's position, plus a pending pickup.** The same path
  construction, the same broadcast, the same degenerate rules. **There is no distance carve-out
  in path assignment.**
- The one difference from `move_to`: **a degenerate pickup by a stationary player is not an
  error.** `move_to` answers "already there" because nothing is left to do. A pickup standing on
  its own item has something left to do, so it assigns no path, broadcasts nothing, and lets the
  pending pickup resolve on the next tick.
- **`PickupRange` governs resolution only, never path assignment.** It is the distance at which
  the tick loop hands you the item. It is not, and must never become, a distance at which the
  server declines to walk you.

  **This clause was wrong when first written and the M1a writer found it by watching a test
  hang.** The original said that a player already within `PickupRange` gets no path at all. That
  is fine for a player standing still and broken for a player walking: the earlier walk is never
  replaced, the player leaves the range on the next tick, and the pending pickup never resolves
  for the rest of the session. The writer patched it by halting the walker, which works and
  which was the right call for a worker holding a hanging test.

  The rule above is a different fix, and it is the one that binds. It deletes the carve-out
  instead of adding a second one under it. **It also dissolves a coupling the same writer flagged
  as real and unenforced**: with `PickupRange` deciding whether to walk, `PickupRange` had to
  stay above `WalkSpeed * TickDuration`, or a walker could step over an item in one tick and
  never be handed it. Those two numbers are `0.5` and `0.45`, which is a five-hundredth of a
  world unit of margin protecting a silent failure, guarded by nothing. Path assignment keys on
  `MinPathLength` instead, at `1e-3`, and the invariant stops existing rather than being
  enforced. A rule with one fewer special case is a rule with one fewer place to be wrong, which
  is the whole lesson of the paragraph above it.
- **A pending pickup resolves inside the tick loop, in `step`, after movement has advanced.**
  Removing the item from the world, writing it to the player's inventory, broadcasting
  `item_despawn`, and sending that player their new `inventory` all happen in that one tick on
  the state-owning goroutine. That is the transaction boundary (`CLAUDE.md`), and it is why
  exactly one player can win.
- **A player has at most one pending pickup.** A second `pickup` replaces the first. A `move_to`
  cancels it, because clicking the ground is telling the server you wanted something else.
- **When the item is gone before you reach it**, the loser is sent a **one-element halt path at
  its current position** and an `error` naming `pickup`. This is the case this file predicted
  when it made a one-element path mean "halt here", and it is why no `stop` message was ever
  needed. Walking on to an empty patch of ground would be the server lying about the world.
- **When the inventory is full on arrival**, the player simply stops there and is sent an
  `error`. The item stays on the ground. No halt path is needed, because arriving already ended
  the walk.
- `pickup` for an id that is not a live ground item is answered with an `error` and nothing
  else. This covers both a stale id and a fabricated one, and it is deliberately one case rather
  than two, because the server must not tell a client which ids exist.

### Contested pickup, and who wins

Two players walking to one item is the M1 milestone. Both arrive, possibly on the same tick, and
the server must hand the item to exactly one.

**Resolution is by player join order, deterministically.** `step` iterates players in the order
they joined, and the first one that both has a pending pickup for that item and is within
`PickupRange` of it takes it. The item leaves the world in that same iteration, so every later
player in the same pass finds it gone and takes the loser's path above.

Join order is arbitrary as a fairness rule and is chosen for being *decidable*, which the
alternatives are not: wall-clock arrival is not available to a tick loop that never reads a
clock, and intent arrival order is a property of the network rather than of the game. It is
deterministic, it replays identically, and a test can state the expected winner rather than
asserting a disjunction. Revisitable the first time it feels unfair to a human, which needs a
human playing.

**Same-tick arrival is the ordinary case, not the corner case**, because everyone spawns at the
origin and walks at one speed, so two players clicking the same item are equidistant from it.
The contest is the default, which is convenient: it means the milestone test does not have to
engineer a race.

### Drop

`drop` is immediate. No walk, no pending action. The item leaves the slot and appears at the
player's position at that tick, `item_spawn` goes to everyone including the dropper, and the
dropper gets a new `inventory`.

**A dropped item gets a new item id. Dropping and picking up the same object twice yields three
different ids, and none of them is reused.** This follows from two rules already stated, that ids
are assigned sequentially as items enter the world and are never reused, but it was only ever
implicit and the first client author to draw an item is the one who has to know it. An inventory
holds *kinds*, not ids: once an item is carried, the id it had on the ground is gone and there is
nothing to restore. So a client must key its item bodies on whatever id `item_spawn` carries and
must never assume an id survives a round trip through somebody's pockets.

Dropping while walking is legal and the item lands where the player is at that tick, not at the
end of the path. An empty slot, or an index outside `0` to `size - 1`, is answered with an
`error` and nothing else.

Drop exists in M1 because it is pickup's reverse transaction. It tests atomicity in the other
direction for no content work at all (`NOTES.md`, M1).

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
   **M1** puts the joining player's first `inventory` inside that same step, last. Nothing about
   the world may be observable to the newcomer before it has been told everything the step
   describes.
4. A connection whose send queue is full is closed. It is never waited on. The tick loop must
   not be blocked by a slow client.

**Three ways a slow client dies, and which one wins is a race.** A send queue that fills
reports one reason. A write that blocks past the write timeout reports another. And when that
timed-out write tears the connection down, the read pump can reach the close first and report
a third, a read error, for what was actually a slow client.

Which detector fires depends on the send rate into a jammed socket, not on anything the code or
this file states. Measured against a real stalled peer: sustained traffic above roughly
thirteen frames per second fills the 64-slot queue inside the write timeout's window, so the
queue wins. Below that the timeout wins, and it can surface as a read error. **M0's ordinary
traffic is the slow case**, because M0 has no per-tick broadcasts and no heartbeat, so a
stalled client jams nothing for minutes and then dies by timeout. The queue branch is reached
in the test suite only by a deliberate flood of oversized frames.

### Which reason is authoritative. **M1**, decided.

**The cause is authoritative, never the detector, and the first condemnation latches.**

Two rules, and both are needed. Either alone leaves the reason racy.

1. **Classify by cause.** A full send queue and a write timeout are two detectors for one
   condition, the client has stopped keeping up, and both report `reason: "slow_client"`. The
   detector's own name goes in a `detail` field, which is for a human reading a log. A read
   error that is not downstream of a condemnation is a different condition, the peer went away
   or the socket broke, and reports `peer_gone`.
2. **Latch on first condemnation.** A connection is condemned exactly once. Whichever component
   condemns it first records the reason, and every later observation of that same dying
   connection is logged under the existing reason rather than overwriting it. This is what
   covers the third case above, where a timed-out write tears down the socket and the read pump
   then reports a read error for what was already a condemned slow client. The read error is a
   consequence of the condemnation, and a consequence must never overwrite a cause.

Rule 1 alone still races, because which of the two slow-client detectors fires depends on the
send rate. Rule 2 alone still races, because it makes the answer stable per death without
making it mean the same thing twice.

**This is deliberately a decision the code can implement without knowing which detector wins.**
The previous version of this section tried to settle the question by describing the race, and
the description had to be corrected once already by a probe against a real stalled peer. A
semantics that depends on winning a race we do not control is a semantics that will be wrong
again. Classifying and latching does not depend on it at all.

Revisitable when **M2d** adds a heartbeat, which changes the traffic rate this section measured and
therefore changes which detector ordinarily fires. It does not change which reason is reported,
which is the point.

**The vocabulary, complete. M1f, shipped; `refused` added by M2a.** Six reasons and four
details. A reason is a cause;
a detail names the detector that noticed and exists only for a human reading a log. Nothing on
either side of the wire branches on a detail, and the server writes both into
`client_disconnected`, omitting `detail` where the cause admits only one detector.

| `reason` | `detail` | What happened |
|---|---|---|
| `closed` | — | The peer sent a close frame, and nothing else produces this. Not a condemnation. |
| `slow_client` | `send_buffer_full` | The 64-frame send queue was already full. |
| `slow_client` | `write_timeout` | One frame's write outlived the five-second write timeout. |
| `peer_gone` | `read_error` | A read failed on something other than a close frame. |
| `peer_gone` | `write_error` | A write failed for a reason that was not the timeout. |
| `server_shutdown` | — | The server is going away. |
| `protocol_error` | — | The client sent an uninterpretable frame and was told so first. |
| `refused` | — | **M2a.** The connection presented a session token whose player is still connected, and was closed at the door. |

**`refused` is the one reason that never appears in a `client_disconnected` line, and that is
the rule rather than an omission.** Every other row describes a connection the world admitted
and then lost, so the world has a player id to log it against. A refused connection is turned
away before any player exists for it: nothing is created, nothing is broadcast, and the only
record is one `resume_refused` naming the remote address. A reader counting
`client_disconnected` to ask "how many players left" must not be handed connections that never
arrived.

It joins this table anyway, because the table is the closed vocabulary of latched reasons and a
reason that is latched but undocumented is worse than one that is documented as never being
logged here. *When the connection dies*, server half, is where the refusal itself is specified.

**A write error that is not a timeout reports `peer_gone`. M1f, decided, revisitable.** This
section did not cover it: it named the write *timeout* as a slow-client detector and said
nothing about a write that fails outright. The call is that "the peer went away or the socket
broke" above already describes it exactly, and the only thing that differs from the read-side
case is which pump happened to touch the socket first — which is a detector, and detectors do
not get to be reasons. So it is `peer_gone` with `detail: "write_error"`.

Revisit if a class of write failure ever turns out to mean something a server can act on
differently from a vanished peer. Nothing in M1 distinguishes them, and inventing a third cause
before anything can use it would be inventing a distinction the log's reader cannot act on.

**`protocol_error` latches when the close is dequeued, not when the world decides it.** A refusal
that closes the connection is queued behind the `error` frame explaining it, so that the client
is told why before the socket goes. The latch therefore does not hold the reason during that gap.
A client that reads the `error` and closes cleanly in reaction can get its own close frame
latched as `closed` first, and the server loses the record that it was hung up on for a protocol
violation. **This cannot happen today**: the Godot client only warns on a server `error` and does
not close. It is recorded because the obvious next behaviour for a client — close when told you
sent garbage — is the one that triggers it, and because a violation logged as an ordinary logout
is precisely the confusion the cause-over-detector rule exists to prevent. Fix it, if a client
ever does that, by latching at the world's decision rather than at dequeue.

**The server owns the write deadline for data frames, and that is what makes the latch true
rather than likely.** Handed a context with a deadline, `coder/websocket` v1.8.15 arms a timer
that closes the whole connection and only then returns the error to the caller (`conn.go:171`,
`setupWriteTimeout`). So the read pump wakes on an already-dead socket and can condemn it
`peer_gone` before the write pump has classified anything: the consequence overwrites the cause,
which is the exact failure rule 2 forbids. The write pump therefore runs its own timer, condemns
first, and lets the resulting close abort the write. By the time anything else can see a dead
socket the reason is already recorded.

**The race is measured; the mechanism above is read.** Reverting the fix makes the ordering test
fail repeatedly and reproducibly — five runs in ten when this was written, three in ten and six
in twenty when a reviewer reran it on a differently loaded machine, every failure the identical
line. That the *cause* is `setupWriteTimeout`'s close timer is inference from the source, and this
file has been wrong about this library's internals three times. It is flagged rather than
polished because the fix does not depend on it: owning the deadline removes the race whatever
arms the teardown.

**"For data frames" is a real limit, not throat-clearing.** `writeControl` wraps whatever context
it is handed in a five-second one (`write.go:277`), `context.Background()` included, and
`writeFrame`'s first act is `writeFrameMu.lock(ctx)`, which returns that context's error wrapped
when the wait expires (`conn.go:291`). The write mutex is held for the whole of a jammed data
frame, so a pong queues behind it and dies on the library's clock, on the *read* goroutine. We can
neither remove that deadline nor shorten it. It reaches the read pump as
`failed to acquire lock: context deadline exceeded` — which is why `readReason` classifies a
context error as `peer_gone` and not as `closed`. Reporting it as a clean logout is the same
rule-2 failure wearing different clothes, and the first version of this section shipped exactly
that bug because it reasoned that `context.Background()` has no deadline instead of checking what
the library does with it. `TestAJammedPongCondemnsTheClientAsPeerGone` stages it end to end.

**This paragraph named the wrong mechanism once, and the correction is the point.** It previously
blamed `finishRead`'s `ctx.Err()` overwrite at `read.go:255` and the connection-closing timer at
`conn.go:171`. Both were wrong here. `finishRead` tests the context it was *passed*, which on this
path is `readPump`'s `context.Background()`, whose `Err` is always nil; and nothing in the library
closes the connection in this scenario — our own `close` does, after the classification. **Three
separate mechanisms for this library were established by reading during M1f and all three were
wrong, while the behaviour each described was real.** That is the combination worth naming: the
symptom happens, so the explanation feels confirmed, and nobody re-checks it. Against this
dependency, claims about *what happens* are cheap to observe and claims about *why* are not
trustworthy until they are.

Two dependency claims sit under that, and both were probed against a real jammed peer rather than
assumed. A deadline-bearing write *does* fail with something `errors.Is`-comparable to
`context.DeadlineExceeded`, so the original design was not wrong about the error — it was wrong
about the ordering, which is a thing no amount of reading the error would have revealed. And
closing the socket from another goroutine unblocks a write jammed on it, which is what the
server's own timer relies on; `TestClosingTheSocketUnblocksABlockedWrite` pins it, because if a
dependency upgrade broke it a slow client would jam forever instead of being dropped.

**Client.** Appliers are idempotent, because a redundant message is cheaper to tolerate than to
prevent.

- `spawn` for an id already known **replaces** rather than adding a second avatar.
- `despawn` for an unknown id logs and ignores.
- `path` for an unknown id logs and ignores.

**M1** extends the same rule to items, and no further:

- `item_spawn` for an item id already known **replaces** rather than adding a second body.
- `item_despawn` for an unknown item id logs and ignores.
- `inventory` always replaces wholesale. There is no partial-inventory message to reconcile.

**A second `welcome` frees every item body as well as every player body**, for the reason the
`welcome` section already gives: a restatement makes everything the client believed beforehand
stale by definition, and items are part of the world it restates.

## Identity

Player ids are integers assigned sequentially from 1 as players enter the world. They are never
reused within a process lifetime and carry no meaning across a restart. `welcome` reissues `you`
on every connection, so nothing may assume an id is stable.

**This paragraph used to say ids are "connection-scoped" and that one is assigned "as
connections arrive", and M2a made both false.** A player now outlives its socket, so the id is
scoped to the player and a resumed connection is handed the id it had before. Two connections
therefore share one id over a player's life, one after the other and never at once. The rule
that survives unchanged is the one that matters to a client: read `you` out of every `welcome`
and never assume it.

**M1** adds item ids, which are a **separate sequence in a separate space**. See *Items and
inventory*, *Entity naming*. Player 1 and item 1 are unrelated.

There is no connection limit in M0.

### The session token. **M2a**, shipped.

Reconnect requires mapping a connection to a durable identity before per-identity sequence
dedupe means anything. `welcome.session` is that mapping.

- **It is an opaque string, 32 hexadecimal characters from a cryptographic random source.** One
  per player, minted when the player enters the world, **the same across every resume of that
  player**, and gone when the player leaves it. Opaque means opaque: nothing derives a player id
  from it, nothing orders two of them, and a client that parses it is reading a number that is
  not there.
- **It is never written to the event log.** Every event that is about a resume names the player
  id or the remote address instead. A token in a log is a token in every place a log is pasted,
  and the log is read by agents and quoted into pull requests.
- **A client presents it as the `session` query parameter of the WebSocket URL**,
  `ws://host/ws?session=<token>`. One mechanism, deliberately: a header would work equally well
  and having two ways to say the same thing means one of them is eventually the wrong one.

  Verified 2026-09-03 against a stdlib Go handler: Godot 4.7.2's
  `WebSocketPeer.connect_to_url("ws://.../ws?session=qry123")` arrives with
  `r.URL.RawQuery == "session=qry123"`. `handshake_headers` also exists and also arrives; it is
  not used.
- **A connection presenting no token is a fresh join**, which is every connection before M2a and
  every first connection after it.

What a client does with it is one rule: **keep the token from your last `welcome`, and present
it on your next connection to the same server.** A token whose player has expired or is unknown
gets a fresh player, and the client can tell because `you` and `session` both differ from what
it held. A token is not a login and is not a secret worth defending; see *Deliberately absent*.

## When the connection dies

### Server. **M2a**, shipped.

**Deaths split by cause, never by detector and never by detail.** The reason the connection died
already answers whether the player meant to go, so nothing new has to be decided at the socket.

- **`closed` and `protocol_error` retire the player at once**, exactly as M1 did: `despawn` is
  broadcast, the inventory is deleted, the id is never issued again, and the session token dies
  with the player. `server_shutdown` needs no rule; the world is going away underneath it.
- **`peer_gone` and `slow_client` suspend the player** for `ResumeGraceTicks`, which is **400
  ticks, sixty seconds at 150 ms**. The body stays in the world. No `despawn` is broadcast,
  because nothing about the world has changed for anyone else: the walk finishes on schedule, a
  pending pickup resolves into the kept inventory, and every frame the suspended player would
  have received is dropped.

RuneScape is the tiebreaker and it splits them the same way. Logging out removes you from the
world at once. A dropped connection leaves your character standing there for a while, which is
what makes reconnecting worth doing.

**Expiry is counted in ticks, checked in the tick loop, and never against a wall clock.** The
tick counter is the clock (see *Clock*), and a suspension that expired against `time.Now()`
would be the one rule in the game that a paused process gets wrong. A suspension that reaches
its expiry tick retires the player exactly as a clean logout does, `despawn` included.

**Each suspension restarts the grace; it is not a budget spent across a session.** A player that
is suspended, resumed, and suspended again gets a full `ResumeGraceTicks` from the second death,
because the second death is a fresh accident and nothing about the first one makes the player
less likely to come back. The alternative, a total the player is allowed across its whole life,
would retire somebody mid-reconnect for having reconnected before, which is the opposite of what
the grace is for. Resuming clears the expiry outright: a connected player has no expiry tick at
all.

**Resume.** A connection presenting a suspended player's token is handed that player: the
ordinary atomic welcome step, with the same `you` and the same `session`, the world as of now,
one re-anchored `path` per walker **including its own**, and then its `inventory`. **No `spawn`
is broadcast**, because everybody already has that body and a second one would be a duplicate
avatar. From every other client's side a resume is not an event at all.

**A token whose player is still connected is refused, not superseded.** The new connection
receives `{"error":{"msg":"session is still connected"}}`, with no `re` because no message was
rejected, and the socket is closed behind it. No player is created for it and it is never
admitted to the world. The connection that already holds the player is untouched.

That is RuneScape's "already logged in" answer, and it is the only one available today:
superseding would mean telling the older connection to stop, and there is no server-to-client
"you have been replaced" signal in this protocol. Inventing one to serve a case nobody has hit
would be inventing a message before anything can use it. **Revisitable**, and the thing to
revisit if a real client ever gets stuck holding its own player out.

**An unknown or expired token is a fresh join**, logged and otherwise indistinguishable from a
connection that presented nothing. The client can tell, because `you` and `session` differ from
what it held.

**Log vocabulary.** Five events, each with its own field set, and no field added to an existing
event:

| Event | Fields | When |
|---|---|---|
| `player_suspended` | `player`, `expires_tick` | a `peer_gone` or `slow_client` death |
| `player_resumed` | `player`, `remote` | a connection presented a suspended player's token |
| `player_expired` | `player` | the grace ran out and the body was retired |
| `resume_refused` | `remote` | the token named a player that is still connected |
| `resume_unknown` | `remote` | a token was presented and named nothing |

`client_disconnected` is still logged for every socket death the world admitted, with its
latched reason, exactly as M1 wrote it. A suspension is a `client_disconnected` followed by a
`player_suspended`, not one instead of the other: the socket really did die, and the reason it
died is what decided the suspension.

None of the five carries the token, per *Identity*. `resume_refused` and `resume_unknown` carry
`remote` and no player id because there is no player to name: one refers to a connection the
world declined to admit, and the other to a token that names nothing.

### Client.

**A client freezes the world it has and logs loudly. It does not clear it.**

The compatibility rules above govern frames. This governs the socket itself, which they never
did. M0 has no reconnect, so a dead socket is terminal for that session.

Clearing the world on disconnect asserts something the server never said, namely that everyone
logged out. Frozen state is stale, but there is no UI to explain either condition, and
stale-and-announced beats false-and-silent.

**Freezing is still the rule, and M2a changed what it costs rather than what it is.** The
sentence above about a dead socket being terminal is now true only of the client, and only for
the two deaths that suspend. After a `peer_gone` or a `slow_client` death the server holds the
body and the inventory for the grace, so a frozen world is stale about something that is waiting
rather than about something that is gone. After a `closed` or a `protocol_error` death it holds
nothing at all, the player is retired at once, and the frozen world is stale in the old sense:
those bodies are gone and are not coming back. Reconnecting is what
cashes that in, and no shipped client does it yet — the client half of reconnect is a later M2
unit, and M2a is server-only.

## Decoding notes for the Godot side

Reported by the writer of the Go server, which had to produce all of this. Each one is a place
a GDScript client will get it subtly wrong.

- **`JSON.parse_string` returns every JSON number as a `float`.** `welcome.tick` and
  `path.start_tick` are 64-bit integers on the wire and arrive as floats. Convert with `int(...)`
  before comparing. No precision is lost, since a float64 holds tick counts exactly for far
  longer than this project will run, but a GDScript `==` against an int will bite someone.
- **`welcome.last_seq` is a 64-bit integer and arrives as a float too**, for the reason above.
  Convert with `int(...)` before comparing it to the number you last sent. A client resuming its
  numbering from `float` arithmetic will be right for far longer than this project runs and wrong
  in the one way that is hard to see coming.
- **A `seq` you send must be written as a JSON integer literal.** `5`, never `5.0`. Measured
  against Go's `encoding/json` on 2026-09-04: unmarshalling into an integer field rejects `5.0`,
  `1e2` and `"7"` outright, so a client that stringifies a whole number as a float sends a frame
  this server refuses as `malformed_json`. The value being integral is not enough; the literal
  has to be one. Keep the counter a GDScript `int`, which stringifies correctly, rather than a
  `float` that happens to hold a whole number.
- **Coordinates have two encodings, deliberately.** `welcome.players[]` and `spawn` use
  `{"id":..,"x":..,"z":..}` because they carry an id. `path.points` uses `[[x,z],...]` because
  an array is materially smaller for a polyline. So a client writes `Vector2(d.x, d.z)` in one
  place and `Vector2(p[0], p[1])` in the other for the same idea. This is a real cost, accepted
  knowingly; it is written here so the second one gets written correctly.
- **M1's item messages use the id-carrying encoding**, `{"id":..,"kind":..,"x":..,"z":..}`, the
  same shape as `spawn` and `welcome.players`. Nothing about an item is a polyline, so the
  packed `[x,z]` form does not appear there. `inventory.slots` carries no coordinates at all.
- **`error.re` is absent rather than null when the frame could not be attributed.** Use
  `d.get("re", "")`. A malformed frame yields `{"error":{"msg":"text frames only"}}` with no
  `re` key at all.
- **`x` and `z` are ground-plane world coordinates.** When they land in a `Vector2`, the
  `Vector2.y` component holds world **Z**. This has caught people already.

## Deliberately absent

Named so nobody adds them thinking they were forgotten.

- No authentication. Ids are sequential and unverified.
- No acks. **M2b** ships sequence numbers, so this line no longer covers them: `seq` is on the
  wire and the server dedupes on it. What M2b deliberately did **not** ship is an
  acknowledgement message. `welcome.last_seq` is a cumulative restatement and stands in for one,
  which is enough for every client that does not replay, and no client replays. **Revisitable**
  the first time one does. See *Sequence numbers*.
- No heartbeat on the wire. **M2d.** The client's side of `tick` is specified under *Clock* and
  implemented (M2c); nothing sends one yet.
- No authentication behind the session token. **M2a** makes a connection able to prove which
  player it was, and nothing more: a token is a bearer credential over a plaintext socket, so
  anyone who can read the wire can resume as you. That is the same standard as the ids above,
  which are sequential and unverified, and it is stated here so nobody mistakes the token for a
  login.
- No banking, trading, crafting, or item stacking. M1 has one item type, one item per slot, and
  the ground as the only container outside a player's own inventory.
- No item ownership, drop timers, or per-player visibility. RuneScape hides a drop from everyone
  but the dropper for a minute; Marque does not, because M1 has no combat and no loot to
  protect, and a hidden item cannot be contested by two clients. **Revisitable**, and the first
  thing to revisit if items ever have value.
- No durability, decay, or despawn timers on ground items. An item lies there until somebody
  takes it or the process exits.
- No camera, facing, or view direction, ever. The camera is pure client presentation and the
  server does not know it exists.
- No per-tick position broadcasts. Waypoints only.
- No interest management. Everything broadcasts to everyone.
