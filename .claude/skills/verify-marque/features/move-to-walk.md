# Move-to walk

A `move_to` intent walks the player to a ground point. The client resolves a ground
point and sends `move_to`; the server validates it, assigns a straight-line path, and
broadcasts it; the client's walker interpolates along the polyline while the camera
follows.

**No gesture produces `move_to` any more.** ARM-145 removed left-click to move.
Walking in a real session is WASD (see [wasd-move](./wasd-move.md)). `move_to` stays
on the wire and the server still accepts it, so the scripted demos and any scripted
client reach it through `Session.request_move_to`. That is the path this file drives.

## Sub-features

- `move-intent` is the request becoming exactly one `move_to` on the wire.
- `move-path` is the server assigning and broadcasting a path (`path_assigned`).
- `move-walk` is the avatar visibly advancing while the walker's camera follows.
- `move-arrive` is the server recording the walk completing (`arrived`).
- `move-click-inert` is the counterfactual. A real left click on bare ground travels
  picker to session to socket and produces nothing at all.

## How to get to it (user POV)

- There is no player gesture. A player walks with WASD.
- Scripted equivalent: `--click fx,fy --phase 1` names a viewport fraction. The
  client resolves it with `GroundPicker.pick_ground` and calls
  `Session.request_move_to`. The same client also pushes one real
  `InputEventMouseButton` at that pixel before its phases, as the inert-click probe.

## Driving it with run.ps1

Preconditions:

- `DOCTOR OK`; a desktop session.

- **Run the scenario.** `powershell -ExecutionPolicy Bypass -File
  .claude/skills/verify-marque/run.ps1`. Marker: `VERIFY HARNESS OK`. Resolve
  client a's player id `<A>` from its `DEMO joined` line.
- **The ground click reached bare ground.** `client-a.stdout.log` has
  `DEMO groundclick <px> <py> <x> <z>`. The client prints it only after
  `GroundPicker.pick()` answered `Target.GROUND` at that pixel, so the line is proof
  the ray met ground rather than a panel, a body, or the sky. Without that
  precondition the next two assertions pass vacuously.
- **The click moved nobody.** `client-a.stdout.log` has
  `DEMO groundclick_ignored <x> <z>`, which the client prints only after waiting
  1.5s and finding its own body within 0.05 units of where it stood. At 3.0 u/s a
  click that still routed would have carried it about 4 units.
- **The click sent nothing.** `server.stdout.ndjson` has **exactly one** `move_to`
  for player `<A>`, and it is the phase walk. Two would mean the gesture came back.
  `scripts/two_client_demo.ps1` asserts this count directly; `run.ps1` does not
  assert it for you, so count it yourself.
- **Intent sent.** `client-a.stdout.log` has `DEMO walkto <px> <py> <x> <z>`, and
  that `move_to` event's coordinates match its `<x> <z>`.
- **Path assigned.** The GAMELOG has `path_assigned` for player `<A>` with
  `"speed":3` and a two-point polyline.
- **Client drew the walk.** Displacement layer one: `DEMO pos 1 <A> x z` versus
  `DEMO pos 2 <A> x z` in `client-a.stdout.log` is at least 2.0 world units apart
  (the scripted destination is ~6 units away; the shots bracket 1.4s at 3.0 u/s).
- **Server believes the walk.** Layer two: the GAMELOG has an `arrived` event for
  player `<A>` at coordinates matching the path's endpoint. Without this, moving
  pixels prove only that the client interpolated a path, not that the server's world
  moved.
- **Camera followed.** `a_1.png` and `a_2.png` must differ broadly, because the
  walker's own camera moved, so even the top quarter (sky and far ground, where no
  body is ever drawn) changes. The specific missing fact if the walk were fake is
  identical sky bands.

## Gotchas

- The client interpolates paths by itself; the server never sends per-tick
  positions. Every movement claim needs both layers or a stalled server tick loop
  passes unnoticed.
- The inert-click probe proves the ray met ground, not that the event survived the
  GUI layer. A `Control` covering that pixel would swallow the click and the probe
  would still pass. The fractions the harnesses ship with are bare ground; a new
  fraction needs checking against the UI before it proves anything.
- A degenerate destination (already there, standing still) sends `move_to` but
  produces `{"error":{"re":"move_to","msg":"already there"}}` and **no** path
  broadcast. See [rejected-intents](./rejected-intents.md).
- In client code a `Vector2.y` holds world Z; `DEMO pos` prints `x z` in world
  units, which is the pair to subtract.
- A second `move_to` mid-walk replaces the path; `points[0]` of the replacement is
  the interpolated position at processing time, not the previous origin.
