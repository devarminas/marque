# Kill and respawn (PvP combat)

The M5 milestone: two clients place themselves outside `AttackRange`, the
attacker click-engages the victim, walks in, lands period hits of 10 until HP
0, the victim shows the death overlay, respawns to HP 100, and can act again.

## Sub-features

- `out-of-range-engage` — shot 1 distance exceeds `AttackRange`; GAMELOG has
  `attack` then a `path_assigned` for the attacker (walk-in, not an in-range
  degenerate hit).
- `period-hits-to-death` — exactly ten `attack_hit` events of damage 10 with
  descending `target_hp` to 0, plus one `death`.
- `death-overlay-then-respawn` — victim shot 2 reports overlay visible and HP 0;
  shot 3 reports overlay hidden and HP 100; GAMELOG has one `respawn`.
- `act-after-respawn` — victim issues a post-respawn ground click; GAMELOG has a
  `move_to` at or after that `respawn`.
- `demo-pass` — harness exits 0 with `COMBAT DEMO OK` as its last line, and both
  clients print `DEMO done`.

## How to get to it (user POV)

- Walk away from the other player until you are outside melee range. Left-click
  their body: you path in and hit every `AttackPeriodTicks` for 10 damage until
  they die. On death the overlay appears; press Respawn to return to full HP at
  the join spawn, then move again.

## Driving it with scripts/combat_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/combat_demo.ps1`.
- Marker: `COMBAT DEMO OK` on the **last line** of stdout. Exit code must also
  be 0.

The script builds marqued, warms Godot once, starts the server on a free port,
launches client a as `--combat-role attacker` and client b as `--combat-role
victim` with `--combat-shots`, and asserts:

- Server layer: one `attack` from attacker naming victim; a `path_assigned` for
  the attacker at or after that attack; exactly ten `attack_hit` of damage 10
  down to `target_hp` 0; one `death`; one `respawn`; a post-respawn `move_to`
  for the victim; no `attack_rejected` / `respawn_rejected`.
- Client layer: shot 1 distance outside range on both; victim shot 2
  `deathvisible 1` and HP 0; victim shot 3 `deathvisible 0` and HP 100; attacker
  prints `attackclick`; victim prints `relocate`, `respawnclick`, `postmove`.
- Six PNGs over 4KB each and `DEMO done` on both clients.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-combat`: six PNGs, both
client stdout/stderr logs, and `server.stdout.ndjson`.

## Gotchas

- **Roles are asymmetric.** Unlike gather-craft, the clients are not identical:
  one relocates and dies, the other click-attacks. Join order still races, so
  resolve ids from `DEMO joined`, never from window labels alone.
- **Both spawn stacked.** The victim must walk out of `AttackRange` before the
  attack click, or the walk-in claim is vacuous and the harness fails shot 1.
- **Click the body, not `request_attack`.** The demo unprojects the remote
  avatar and pushes a real left click through the picker.
- **Kill takes wall time.** Ten period hits at 4 ticks × 150 ms, plus the walk,
  so the client timeout is 180 s. Do not treat a slow idle desktop as a hang
  until that budget expires.
- **Overlay blocks the world.** Respawn is a click on the authored Respawn
  button; a ground click while dead is refused by the server and would not clear
  the overlay.
