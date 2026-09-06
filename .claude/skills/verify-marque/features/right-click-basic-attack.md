# Right-click basic attack (M6f)

Right-click a hostile (remote player or enemy practice dummy) to start the M5
pending melee loop. Left-click stays select-only. Friendly dummies refuse.

## Sub-features

- `right-click-hostile` — right-click enemy player or hostile dummy → GAMELOG
  `attack`; period hits apply. Selection also moves to the clicked actor.
- `left-click-no-attack` — left-click selects and never starts a pending attack.
- `friendly-refuse` — right-click friendly dummy selects and refuses (client
  `attack_refused` / server `attack_rejected` `wrong_target`); no pending attack.
- `clicked-target` — `attack.player` is the body under the cursor, not merely a
  prior tab selection.

## How to get to it (user POV)

- Right-click another player or the red (hostile) practice dummy: you path in
  and hit on the M5 period. The yellow selection ring follows the click.
- Right-click the green (friendly) practice dummy: ring selects them; no melee.
- Left-click still only selects.

## Driving it with scripts/dummy_attack_demo.ps1

Preconditions:

- `DOCTOR OK` or a local Godot that can run headless tests and the live demos.
- Headless: interaction suite (left vs right on players) and npcs suite
  (friendly refuse / hostile request_attack).
- Live dummies: `powershell -ExecutionPolicy Bypass -File scripts/dummy_attack_demo.ps1`.
  Marker: `DUMMY ATTACK DEMO OK` on the last line; exit 0.
- Live PvP parity: `scripts/combat_demo.ps1` still proves walk-in, period hits,
  death, and respawn via a real right-click (`COMBAT DEMO OK`).

Evidence for the dummy demo lands in `-OutDir` (default
`$env:TEMP\marque-dummy-attack`): client stdout/stderr and `server.stdout.ndjson`.

## Gotchas

- **Right-click also orbits.** Until camera orbit moves off right-press, a drag begun on a
  body still engages. See PROTOCOL M6f deliberate absences.
- **Friendly refuse is client-first.** The client keeps the intent off the wire;
  the server still rejects a fabricated `attack` on a friendly NPC.
- **Remote players are PvP.** There is no player-faction gate; only NPC
  `faction: "friendly"` refuses.
