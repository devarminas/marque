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
- `wasd-relocate` — `request_move` steer displaces the avatar; GAMELOG `move`
  and `path_assigned`.

## How to get to it (user POV)

- Tab or left-click the red dummy, press hotbar 2 (fireball).
- Tab or left-click the green dummy, press hotbar 1 (heal).
- Right-click the red dummy to swing.
- Hold W/A/S/D to walk under server authority.

## Driving it with verify-marque

Preconditions:

- `DOCTOR OK` or a local Godot that can run the live demo.
- Live: `powershell -ExecutionPolicy Bypass -File scripts/tab_combat_demo.ps1`.
  Marker: `TAB COMBAT DEMO OK` on the last line; exit 0.
- Requires DEMO `fireballok`, `healok`, `castfx`, `attackok`, `move_displacement`
  plus GAMELOG `cast_effect`, `attack_hit`, `move`, `path_assigned`, and
  `npc_hp_seed`.

Evidence lands in `-OutDir` (default `$env:TEMP\marque-tab-combat`): client
stdout/stderr, `server.stdout.ndjson`, and optional `tab_combat_*.png`.

## Gotchas

- **Friendly must be wounded.** Heal on MaxHP spends mana but does not raise HP.
  The demo passes `-friendly-hp 50` to marqued.
- **One Godot driver.** Do not run a second `--*-shots` client against the same
  server while this milestone demo is proving AC1–AC5.
- **Left-click is not attack.** The attack phase must right-click.
