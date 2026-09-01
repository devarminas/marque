# Click to move

A left-click on the ground walks the player there. The client raycasts the click to a
ground point and sends a `move_to` intent; the server validates it, assigns a
straight-line path, and broadcasts it; the client's walker interpolates along the
polyline while the camera follows.

## Sub-features

- `move-intent` — the click becomes exactly one `move_to` on the wire.
- `move-path` — the server assigns and broadcasts a path (`path_assigned`).
- `move-walk` — the avatar visibly advances; the walker's camera follows it.
- `move-arrive` — the server records the walk completing (`arrived`).

## How to get to it (user POV)

- Left-click anywhere on the visible ground in a windowed session.
- Scripted equivalent: `--click fx,fy --phase 1` synthesises the same click through
  the same picker → session → socket path.

## Driving it with run.ps1

Preconditions:

- `DOCTOR OK`; a desktop session.

- **Run the scenario.** `powershell -ExecutionPolicy Bypass -File
  .claude/skills/verify-marque/run.ps1`. Marker: `VERIFY HARNESS OK`. Resolve
  client a's player id `<A>` from its `DEMO joined` line.
- **Intent sent.** `client-a.stdout.log` has `DEMO clicked <px> <py>`, and
  `server.stdout.ndjson` has a `move_to` event for player `<A>`.
- **Path assigned.** The GAMELOG has `path_assigned` for player `<A>` with
  `"speed":3` and a two-point polyline.
- **Client drew the walk.** Displacement layer one: `DEMO pos 1 <A> x z` versus
  `DEMO pos 2 <A> x z` in `client-a.stdout.log` is at least 2.0 world units apart
  (the scripted click is ~6 units away; the shots bracket 1.4s at 3.0 u/s).
- **Server believes the walk.** Layer two: the GAMELOG has an `arrived` event for
  player `<A>` at coordinates matching the path's endpoint. Without this, moving
  pixels prove only that the client interpolated a path — not that the server's
  world moved.
- **Camera followed.** `a_1.png` and `a_2.png` must differ broadly — the walker's own
  camera moved, so even the top quarter (sky and far ground, where no body is ever
  drawn) changes. The specific missing fact if the walk were fake: identical sky
  bands.

## Gotchas

- The client interpolates paths by itself; the server never sends per-tick
  positions. Every movement claim needs both layers or a stalled server tick loop
  passes unnoticed.
- A degenerate click (already at the target, standing still) sends `move_to` but
  produces `{"error":{"re":"move_to","msg":"already there"}}` and **no** path
  broadcast — see [rejected-intents](./rejected-intents.md).
- In client code a `Vector2.y` holds world Z; `DEMO pos` prints `x z` in world
  units, which is the pair to subtract.
- A mid-walk click replaces the path; `points[0]` of the replacement is the
  interpolated position at processing time, not the previous origin.
