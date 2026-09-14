# Two clients race for one item

The M1 milestone: one acorn on the ground, two players who both click it on the same
server tick, and exactly one of them ends up holding it. The loser is told, stops
steering, and watches the item vanish. The winner then wish-steers somewhere else and
drops it, and the item reappears there in both worlds.

Approach to the item is server `steerToward` on the pose integrator — not a player
polyline. The walk-away is client wish `move`. Player `path_assigned` / `move_to` must
not appear.

## Sub-features

- `pickup-contest` — one `pickup_resolved` and one `pickup_lost` for the same item id,
  naming different players. This is the milestone sentence.
- `pickup-same-tick` — both `pickup` intents land on the same tick, and
  `pickup_resolved.t` equals `pickup_lost.t`, so only the tick loop's join order
  separates them.
- `pickup-intents` — two `pickup` intents, one per player, and **no** `move_to`
  produced by either of those clicks. A click on an item that resolved to the ground
  under it shows up here as a missing pickup and a stray `move_to`.
- `pickup-seen` — both clients lose the item body from their world and exactly one
  inventory panel fills. A client removes an item body only on receiving
  `item_despawn` and fills a slot only on receiving `inventory`, so this is the run's
  evidence that both frames reached both clients.
- `pickup-no-player-path` — zero player `path_assigned` for the whole run (approach
  and halt are wish/pose, not polyline).
- `pickup-loser-halted` — after `pickup_lost`, the loser sends no further non-zero
  `move` wishes; halt is `clearSteer` + pose broadcast.
- `drop-wish-steer` — the winner logs non-zero GAMELOG `move` wishes, prints
  `DEMO wish` / `DEMO walkaway_arrived`, and `item_spawned` for the drop matches that
  arrived pose within 1.5 (display soft-pull vs server underfoot; DEMO item ↔ spawn
  stay at 0.05).
- `drop-coordinates` — the dropped item's `item_spawned` x and z are neither the
  origin nor where the item was seeded (floors on displacement).
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

Minimum evidence:

| Claim | GAMELOG | DEMO | Pixel |
|---|---|---|---|
| Exactly one winner (**core**) | one `pickup_resolved` + one `pickup_lost`, same item, different players | exactly one client carrying acorn | **cannot prove** |
| Contest timing | same `pickup` intent ticks; `pickup_resolved.t` = `pickup_lost.t` | sync tick prints (tolerate 1) | n/a |
| No polyline | **no** player `path_assigned`, **no** `move_to` | `DEMO wish` on winner | n/a |
| Client saw frames | (via resolved/lost) | item body present→absent→present; inv fill | optional |
| Drop / seed coords | `item_spawned` x,z match `-item` / winner `DEMO walkaway_arrived` | `DEMO item` agreement within 0.05; walkaway↔drop within 1.5 | do not assert from silhouette |

## How to get to it (user POV)

- Two people are in one world with a single item lying on the ground. Both click it at
  the same moment. One of them ends up with an acorn in slot 0; the other stops and
  gets an `error` frame saying the item is gone. The winner then wish-steers elsewhere
  and clicks the acorn in their inventory to drop it.

## Driving it with scripts/contested_pickup_demo.ps1

Default driver rung: **live windowed demo** for client inventory/despawn agreement;
the core contest claim is **GAMELOG-only** and would also falsify on Go if the store
broke. Prefer the live harness when proving both layers together.

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
  `-ItemZ`; two `pickup` intents from two distinct players for that item on the same
  tick; exactly one `pickup_resolved` and exactly one `pickup_lost`, different
  players, between them naming both; no `pickup_rejected` and no `pickup_no_room`;
  `pickup_resolved.t` equal to `pickup_lost.t`; zero player `path_assigned` and zero
  `move_to`; winner has ≥1 non-zero `move` wish; exactly one `drop`, emptying the
  slot the pickup filled and naming a **fresh** item id; exactly two `item_spawned`
  events in total.

  Client layer, from each client's own `DEMO` lines: two player bodies in all three
  captures; one item body, none, then one; nothing carried, exactly one client carrying
  an acorn in the slot the server named, then nothing; and both clients agreeing about
  which of them won. Winner prints `DEMO wish` and `DEMO walkaway_arrived`.

  Layer agreement: the client whose panel filled is the player the log names as the
  winner; both clients draw the dropped item within 0.05 of where the server logged it
  spawning; winner `walkaway_arrived` matches that spawn within 1.5 (display vs
  server underfoot); both clients draw the dropped item within 0.05 of the spawn.

- **The evidence survives the run.** Everything lands in `-OutDir`, default
  `$env:TEMP\marque-contested-pickup`: six PNGs, `client-a.stdout.log` and
  `client-b.stdout.log` with their stderr companions, and `server.stdout.ndjson`, the
  GAMELOG every server-layer assertion reads. Emptied at the start of each run and
  refused outright if something else wrote it.

- **Variant scenarios.** `-ItemX`/`-ItemZ` move the item and `-DropClick` moves the
  winner's destination. Both are constrained: see Gotchas.

## Gotchas

- **Core claim is GAMELOG-only.** Pixels cannot prove exactly-one-winner. Assert
  `pickup_resolved` / `pickup_lost` first.
- **Same-tick pickup clicks use a two-phase Unix wall barrier.** After shot 1,
  wait for the contest world to restore (dual llvmpipe capture can abandon and
  free the seed / drop the peer), then `marque-pickup-ready-*` so neither client
  starts propose alone. Both then freshen `propose <gen> <ready_unix_msec>` in
  `marque-pickup-sync-*` under `--pickup-shots`, settle on
  `fire = max(ready) + POST_CAPTURE_LEAD_MSEC`, then vote
  `commit <gen> <fire> <ready>` in **separate** `marque-pickup-commit-*`
  files after both propose rows converge on the same `fire` value. Once a
  propose row carries a `fire` field, never rewrite it as ready-only — that
  thrash made peers observe `fire=-1` under llvmpipe and exhausted the wall
  lead before a match. If the candidate goes stale mid-converge, bump
  `fire = now + POST_CAPTURE_LEAD_MSEC` rather than spinning until the join
  timeout. Commit does **not** abort on a brief peer `ready=0` (that asymmetric
  early exit left one client firing alone under llvmpipe); it waits until
  unanimous ready or timeout. Only a unanimous ready commit waits for the wall
  deadline (busy-spin the last `WALL_SPIN_REMAINING_MSEC` so llvmpipe frames
  cannot overshoot), then a final `marque-pickup-go-*` rendezvous that **must**
  see the peer before either fires `request_pickup` (go miss retries the next
  barrier generation — do not fire alone). `request_pickup` is used instead of
  `push_input`, which only reaches the session on a later frame under software
  GL. Do **not** schedule via `TickClock.start_usec_of(aim_tick)` — even a frozen
  per-process usec still diverges under GLES re-anchors and was landing intents
  5–15 server ticks apart. `DEMO sync`'s second field is the shared
  `fire_unix_msec` (harness parses it as Int64). Production `World.Run` is
  unchanged — same-tick is a demo harness concern. The harness may retry the
  whole contest a few times if GAMELOG still shows split ticks
  (`MaxContestAttempts`, default 5).
- **40ms wish walk-away budgets.** Server `TickDuration` is 40ms (3.0 u/s → 0.12
  u/tick). The drop-walk span is ≈5.57u (≈47 ticks). Client offsets in
  `pickup_demo.gd` are wall-scaled from the old 150ms schedule so the walk-away
  window covers that span; a 38-tick budget only reaches 4.56u and never prints
  `DEMO walkaway_arrived`. Arrival itself is a **wall-clock** budget from the
  moment the wish starts (`WALK_AWAY_BUDGET_TICKS` × tick_ms), not
  `click_tick + deadline` on `estimated_tick()`, so clock corrections cannot
  make the deadline already past before the first step. After stop, the demo
  settles briefly so soft-pulled display pose is closer to server underfoot
  before printing `walkaway_arrived`, and keeps emitting zero wish through bag open so sticky steer cannot restart before the drop. Do not reintroduce path-span tick asserts.
- **There is no `item_despawn` event in the server's event log.** The despawn is a wire
  message only (`server/internal/game/items.go`, `w.broadcast(mnet.ItemDespawn...)`);
  no `EvItemDespawned` exists. A recipe that greps the GAMELOG for it finds nothing and
  that is not a defect in the run. Prove the despawn from `pickup_resolved`, which
  causes it, plus both clients dropping the body.
- **The item must not draw under the inventory panel.** The panel is opaque since M1k
  and swallows every click inside its rect, so an item behind it produces a run in
  which no `pickup` ever arrives — a true statement about a scenario that never
  happened. The client checks the projected position against the panel's own rect and
  prints `DEMO FAIL` rather than clicking, so this is diagnosed rather than debugged;
  but if you move `-ItemX`/`-ItemZ` or `-DropClick`, keep them out of the panel's rect,
  measured as (1024, 272) to (1264, 704) at 1280x720.
- **The dropped item lands under the dropper's feet**, because that is what a drop
  does (`TestDropIsImmediateAndReachesEveryoneIncludingTheDropper`). In the third
  capture it sits at the base of the winner's avatar — this demo seeds an **acorn**,
  drawn as the default green box in `ground_item.tscn` (only `lumberjack_axe` has its
  own model scene). Expect overlap with the avatar, not a clear silhouette. Assert it
  from the `DEMO item` lines and the GAMELOG, not from the pixels.
- **Both clients run identical arguments and neither is told who won.** Each reads it
  off the `inventory` the server sent it. Do not add a flag that tells one of them; the
  claim is that two indistinguishable clients get different answers.
- **The winner is decided by join order** (`world.go`, `step`): the first player in
  `w.order` with a pending pickup and in range takes it. It is reproducible for a given
  connection order and it is *not* reproducible across runs, because the two clients
  race to connect. Both labels have won here. Assert that exactly one won, never which.

  **What decides whether a run was a contest is a server-side number, not the DEMO sync print.**
  The check that decides the milestone is same-tick `pickup` intents plus
  `pickup_resolved.t == pickup_lost.t`.
