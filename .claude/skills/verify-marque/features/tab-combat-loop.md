# Tab combat loop (M6i)

One client closes M6 by observation: select hostile and fireball, select
friendly and heal, right-click basic attack, then WASD relocate. Both DEMO
lines and GAMELOG events must agree.

## Sub-features

- `select-fireball` — select hostile dummy; cast fireball; mana and target HP
  drop; `CastHitFx` on the target; GAMELOG `cast_effect` fireball.
- `select-heal` — select wounded friendly dummy; cast heal; HP up and mana
  down; flash; GAMELOG `cast_effect` heal. The harness seeds friendly HP via
  `-friendly-hp` so heal can raise it.
- `right-click-attack` — right-click hostile starts pending melee; DEMO
  `attackok` and GAMELOG `attack` / `attack_hit`.
- `wasd-relocate` — `request_move` wish displaces the avatar; DEMO
  `move_displacement` / `wish_ok`; GAMELOG non-zero `move`; **no** player
  `path_assigned` / `move_to`. The live demo runs this wish phase before casts so
  range/mana gates cannot skip the wish+pose proof.

## How to get to it (user POV)

- Hold W/A/S/D to walk under server authority (demo relocates first).
- Tab or left-click the red dummy, press hotbar 2 (fireball).
- Tab or left-click the green dummy, press hotbar 1 (heal).
- Right-click the red dummy to swing.

## Driving it with verify-marque

Preconditions:

- `DOCTOR OK` or a local Godot that can run the live demo.
- Live: `powershell -ExecutionPolicy Bypass -File scripts/tab_combat_demo.ps1`.
  Marker: `TAB COMBAT DEMO OK` on the last line; exit 0.
- Requires DEMO `fireballok`, `healok`, `castfx`, `attackok`, `move_displacement`,
  `wish_ok` plus GAMELOG `cast_effect`, `attack_hit`, non-zero `move`, and
  `npc_hp_seed`. Fails closed on player `path_assigned` or `move_to`.

Evidence lands in `-OutDir` (default `$env:TEMP\marque-tab-combat`): client
stdout/stderr, `server.stdout.ndjson`, and optional `tab_combat_*.png`.

## Gotchas

- **Friendly must be wounded.** Heal on MaxHP spends mana but does not raise HP.
  The demo passes `-friendly-hp 50` to marqued.
- **Wish before cast.** Relocate runs first so `wish_ok` / non-zero `move` stay
  reachable if a later fireball mana/range gate flakes. Spawn-to-hostile is 3.0
  with fireball range 8; the driver also closes in before cast. A remaining
  "did not spend mana" with in-range poses is usually kit/class or env, not
  wish+pose.
- **Practice dummy, not last hostile.** Join worlds also spawn imps. Target
  selection filters `kind == dummy` so a later hostile imp cannot overwrite the
  practice dummy and pull close-in into the camp.
- **One Godot driver.** Do not run a second `--*-shots` client against the same
  server while this milestone demo is proving AC1–AC5.
- **Left-click is not attack.** The attack phase must right-click.
