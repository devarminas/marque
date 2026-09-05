# Two clients race for one item

The M1 milestone: one acorn on the ground, two players who both click it on the same
server tick, and exactly one of them ends up holding it. The loser is told, stops
where it stands, and watches the item vanish. The winner then walks somewhere else and
drops it, and the item reappears there in both worlds.

## Sub-features

- `pickup-contest` — one `pickup_resolved` and one `pickup_lost` for the same item id,
  naming different players. This is the milestone sentence.
- `pickup-same-tick` — both walks to the item start on the same tick and span the same
  distance, so the two players reach it together and only the tick loop's join order
  separates them.
- `pickup-intents` — two `pickup` intents, one per player, and **no** `move_to`
  produced by either of those clicks. A click on an item that resolved to the ground
  under it shows up here as a missing pickup and a stray `move_to`.
- `pickup-seen` — both clients lose the item body from their world and exactly one
  inventory panel fills. A client removes an item body only on receiving
  `item_despawn` and fills a slot only on receiving `inventory`, so this is the run's
  evidence that both frames reached both clients.
- `pickup-walk-plausible` — the winner's walk to the item took as many ticks as
  walking that far takes, not one tick.
- `pickup-loser-halted` — the loser's halt, the one-point `path_assigned` the server
  sends it on the tick it loses, puts it within `PickupRange` of the item. Every other
  assertion about the loser is about what it did not receive, and a loser left standing
  at the origin satisfies all of them.
- `drop-coordinates` — the dropped item's `item_spawned` x and z equal where its
  dropper arrived, and that point is neither the origin nor where the item was seeded.
- `seed-coordinates` — the seeded item's `item_spawned` x and z equal what `-item`
  asked for.

The last two exist because **nothing in this repo asserted `item_spawned`'s x or z**
until this feature landed, for drops or for seeds. A verifier zeroed those coordinates
and every Go test stayed green, because the store and the wire stayed truthful and only
the log lied. Anything downstream that reads the log as ground truth — this harness
included — was wrong and had no way to say so.

`pickup-contest` is not provable from pixels at all, at any effort. Two clients that
both drew an empty patch of ground look identical whether the server gave the item to
one player, to both, or to neither. Only the GAMELOG carries it.

## How to get to it (user POV)

- Two people are in one world with a single item lying on the ground. Both click it at
  the same moment. One of them ends up with an acorn in slot 0; the other stops short
  and gets an `error` frame saying the item is gone. The winner then clicks the ground
  somewhere else, walks there, and clicks the acorn in their inventory to drop it.

## Driving it with scripts/contested_pickup_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else running against the same checkout's
  `client/.godot`.
- **Nothing else on the machine.** The clients synchronise on the server's own tick
  clock, so load does not desynchronise them, but each capture still waits 15 rendered
  frames and a starved display stretches that without bound.

- **Run the canonical scenario.** `powershell -ExecutionPolicy Bypass -File
  scripts/contested_pickup_demo.ps1`. Marker: `CONTESTED PICKUP DEMO OK`, and it must
  be the last line — read the tail, do not grep. Its assertions are baked in. About 30
  seconds on an idle machine.

  It starts `marqued` with `-item -5,-5,acorn` and exactly that, runs two windowed
  clients with **identical arguments** — nothing distinguishes them, which is the
  point — and asserts three layers.

  Server layer: `seeded_items` is 1; the seed's logged coordinates match `-ItemX`/
  `-ItemZ`; two `pickup` intents from two distinct players for that item; exactly one
  `pickup_resolved` and exactly one `pickup_lost`, different players, between them
  naming both; no `pickup_rejected` and no `pickup_no_room`; both contested
  `path_assigned` events on the same `start_tick` with equal spans and both ending on
  the item; `pickup_resolved.t` equal to `pickup_lost.t`; exactly one `move_to` in the
  whole run, by the winner; exactly one `drop`, emptying the slot the pickup filled and
  naming a **fresh** item id; exactly two `item_spawned` events in total.

  Client layer, from each client's own `DEMO` lines: two player bodies in all three
  captures; one item body, none, then one; nothing carried, exactly one client carrying
  an acorn in the slot the server named, then nothing; and both clients agreeing about
  which of them won.

  Layer agreement: the client whose panel filled is the player the log names as the
  winner, and both clients draw the dropped item within 0.05 units of where the server
  logged it spawning.

  Walk plausibility, on both of the winner's walks: `arrived.t - start_tick` against
  `ceil(span / (WalkSpeed * TickDuration))`, tolerance 2 ticks. Healthy figures on this
  machine are 16 ticks for the 7.071-unit walk to the item and 13 for the 5.567-unit
  walk away, both exactly the ideal.

- **The evidence survives the run.** Everything lands in `-OutDir`, default
  `$env:TEMP\marque-contested-pickup`: six PNGs, `client-a.stdout.log` and
  `client-b.stdout.log` with their stderr companions, and `server.stdout.ndjson`, the
  GAMELOG every server-layer assertion reads. Emptied at the start of each run and
  refused outright if something else wrote it.

- **Variant scenarios.** `-ItemX`/`-ItemZ` move the item and `-DropClick` moves the
  winner's destination. Both are constrained: see Gotchas.

## Gotchas

- **There is no `item_despawn` event in the server's event log.** The despawn is a wire
  message only (`server/internal/game/items.go`, `w.broadcast(mnet.ItemDespawn...)`);
  no `EvItemDespawned` exists. A recipe that greps the GAMELOG for it finds nothing and
  that is not a defect in the run. Prove the despawn from `pickup_resolved`, which
  causes it, plus both clients dropping the body.
- **The item must not draw under the inventory panel.** The panel is opaque since M1k
  and swallows every click inside its rect, so an item behind it produces a run in
  which no `pickup` ever arrives — a true statement about a scenario that never
  happened. Before M1k the ending differed and the problem did not: the click walked
  the player instead of picking anything up. The client checks the projected position
  against the panel's own rect and prints `DEMO FAIL` rather than clicking, so this is
  diagnosed rather than debugged; but if you move `-ItemX`/`-ItemZ` or `-DropClick`,
  keep them out of the panel's rect, measured as (1024, 272) to (1264, 704) at
  1280x720.
- **The dropped item lands under the dropper's feet**, because that is what a drop
  does (`PROTOCOL.md`, *Drop*). In the third capture it sits at the base of the
  winner's avatar — the axe is drawn with its own model now rather than a
  placeholder, so look for the axe, not a coloured sliver, and expect overlap, not
  a clear silhouette. Assert it from the `DEMO item` lines and
  the GAMELOG, not from the pixels.
- **Arriving and dropping on the same tick is correct.** The tick loop steps movement
  and then drains intents, so a drop handled in the arrival tick uses the arrival
  position; measured at ticks 79 and 80 on one run and 83 and 83 on another, with the
  coordinates matching exactly both times. Only a drop on an *earlier* tick than the
  arrival is wrong.
- **Both clients run identical arguments and neither is told who won.** Each reads it
  off the `inventory` the server sent it. Do not add a flag that tells one of them; the
  claim is that two indistinguishable clients get different answers.
- **The winner is decided by join order** (`world.go`, `step`): the first player in
  `w.order` with a pending pickup and in range takes it. It is reproducible for a given
  connection order and it is *not* reproducible across runs, because the two clients
  race to connect. Both labels have won here. Assert that exactly one won, never which.
- **The clients agree on a moment through the server's tick clock**, not wall-clock:
  each reads `estimated_tick()` when it can first see both players and the item, adds a
  fixed lead, and prints the sum. "The two clients aimed at different ticks" is a
  distinct failure from "the server did not resolve a contest".

  **The two numbers are not identical, and this bullet used to claim they were observed
  identical on every run.** Measured over 21 idle runs at M1j, they differ by exactly one
  tick on 15 of them, by nothing on the other 6, and by more than one on none. The cause
  is in the client: each anchors its own `TickClock` at its own `welcome` and
  `estimated_tick()` floors the elapsed time, so two clients anchored at different
  instants inside one 150ms tick cross the floor boundary at different moments and read
  different numbers for the same instant. A one-tick disagreement is the expected
  artifact of that, not a fault, so the harness tolerates one tick here and nothing
  wider.

  **What decides whether a run was a contest is a server-side number, not this one.**
  The two clients printing the same tick does not mean their intents landed in the same
  server tick, and printing different ticks does not mean they did not: over those same
  21 runs the server assigned the two paths on the same tick 13 times, and 7 of those 13
  were runs whose clients had printed different numbers. The check that decides the
  milestone is the one on `path_assigned` start ticks.
