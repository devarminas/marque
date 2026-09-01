# Wire protocol

The single source of truth for what crosses the socket. Server and client are written by
different people who cannot talk to each other, so this file is the contract between them.
It beats any brief, any comment, and any memory. If code disagrees with this file, the code
is wrong.

Amend this file first, then change code. Never the reverse.

Status: M0 shipped. **M1's messages are specified here and not yet implemented**; sections
marked **M1** are the contract the M1 units are being written against, so a reader looking at
today's code will not find them. Sections marked **M2** are reserved and nobody is writing them.

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

**M1** adds a sibling array, `items`, listing every item lying on the ground as of the same
tick:

    {"welcome":{"you":1,"tick_ms":150,"tick":142,
                "players":[{"id":1,"x":0.0,"z":0.0}],
                "items":[{"id":7,"kind":"acorn","x":3.0,"z":-2.0}]}}

`items` is the world, so it belongs in `welcome` alongside `players`. **The joining player's own
inventory is not in `welcome`**; it is private to one player rather than part of the world, and
it arrives as a separate `inventory` message inside the same atomic step. A pre-M1 client
ignores the `items` field under compatibility rule 2 and is exactly as correct as it was before.

**A repeated `welcome` is a full restatement of the world, not a patch.** The server sends
exactly one today, so nothing depends on this yet. But "first message on every connection"
constrains position and never constrained multiplicity, and M2's reconnect makes the answer
load-bearing. A client receiving a second `welcome` frees every body, re-anchors its clock, and
rebuilds from the list. That is the only reading consistent with `welcome` being the whole world
restated: anything the client believed beforehand is stale by definition. It also hands M2's
reconnect its re-anchoring for free.

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
- **A receiver treats `null` as an absent key**, meaning empty, and logs loudly. This is the
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

Revisitable when M2 adds a heartbeat, which changes the traffic rate this section measured and
therefore changes which detector ordinarily fires. It does not change which reason is reported,
which is the point.

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

Player ids are integers assigned sequentially from 1 as connections arrive. They are
connection-scoped, are never reused within a process lifetime, and carry no meaning across a
restart. `welcome` reissues `you` on every connection, so nothing may assume an id is stable.

**M1** adds item ids, which are a **separate sequence in a separate space**. See *Items and
inventory*, *Entity naming*. Player 1 and item 1 are unrelated.

There is no connection limit in M0.

**M2.** Reconnect requires mapping a connection to a durable identity before per-identity
sequence dedupe means anything. That mapping does not exist yet and M0 must not pretend it does.

## When the connection dies

**A client freezes the world it has and logs loudly. It does not clear it.**

The compatibility rules above govern frames. This governs the socket itself, which they never
did. M0 has no reconnect, so a dead socket is terminal for that session.

Clearing the world on disconnect asserts something the server never said, namely that everyone
logged out. Frozen state is stale, but M0 has no UI to explain either condition, and stale-and-
announced beats false-and-silent. Revisit with M2, which is the first milestone where a client
can do something better than freeze.

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
- No sequence numbers or acks. **M2.**
- No heartbeat. **M2.**
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
