# Polish prop: player character (mock, no marqued)

Reusable `client/scenes/props/player_character.tscn` (avatar + CameraRig) shared
by `main.tscn` and the headless polish mock. Proves walk anim, camera attach /
follow, approach pose-stream presentation, jump height presentation, and settle
idle **without** WebSocket or marqued.

## Sub-features

- `prop-shared` — game and mock instance the same `player_character.tscn`
- `wish-walk-anim` — LocalMover wish → `present_at` plays walk while moving
- `camera-attach` — CameraRig target stays the prop avatar; rig follows motion
- `approach-anim` — pose-only stream (no wish) plays walk then idle on settle
- `jump-present` — jump raises avatar `y` via `present_at` height, then lands
- `settle-idle` — zero wish presents idle; camera remains attached

## How to get to it (user POV)

No live server. Open the prop in the editor, or run the headless suite below.
In the game, `main.tscn` instances the same prop as `PlayerCharacter`.

## Driving it with headless Godot

From the repo root:

```bash
godot --headless --path client --script res://tests/run_tests.gd
```

Suite: `client/tests/test_player_character_prop.tscn` (registered in
`run_tests.gd`). Driver feeds `LocalMover` + `present_at` only — no Session net,
no WebSocket.

Markers: exit 0; suite line `PASS: player_character prop mock`; overall last line
`PASS: N assertion(s) held across M suite(s)`.

## Gotchas

- Do not require marqued for these asserts. Wire claims belong under
  `polish/adr-0001-*.md` / `adr-0003-*.md`.
- Remotes still instance bare `player_avatar.tscn` (no camera). Only the local
  character uses the prop.
- Prototype move-to-walk is retired; this mock is the presentation home.
