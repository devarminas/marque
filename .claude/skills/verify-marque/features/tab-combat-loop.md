# Tab combat loop (M6i, ARM-290 split)

M6i live proof is four focused units. The kitchen-sink `tab_combat_demo` is
**retired** (ARM-290 fail-closed stub).

## Sub-features

- `select-fireball` — select hostile dummy; cast fireball; mana and target HP
  drop; `CastHitFx` on the target; GAMELOG `cast_effect` fireball.
  Driver: `dummy_cast_demo.ps1`.
- `select-heal` — select wounded friendly dummy; cast heal; HP up and mana
  down; flash; GAMELOG `cast_effect` heal. Harness seeds friendly HP via
  `-friendly-hp`. Driver: `heal_wounded_demo.ps1`.
- `right-click-attack` — right-click hostile starts pending melee; DEMO
  `attackok` and GAMELOG `attack` / `attack_hit`. Driver: `dummy_attack_demo.ps1`.
- `wasd-relocate` — `request_move` wish displaces the avatar; DEMO
  `move_displacement` / `wish_ok`; GAMELOG non-zero `move`; **no** player
  `path_assigned` / `move_to`. Driver: `wasd_demo.ps1`.

## How to get to it (user POV)

- Hold W/A/S/D to walk under server authority.
- Tab or left-click the red dummy, press hotbar 2 (fireball).
- Tab or left-click the green dummy, press hotbar 1 (heal).
- Right-click the red dummy to swing.

## Driving it with verify-marque

Preconditions:

- `DOCTOR OK` or a local Godot that can run the live demos.
- Live units (each bounded, single claim):
  - `powershell -ExecutionPolicy Bypass -File scripts/wasd_demo.ps1` → `WASD DEMO OK`
  - `powershell -ExecutionPolicy Bypass -File scripts/dummy_cast_demo.ps1` → `DUMMY CAST DEMO OK`
  - `powershell -ExecutionPolicy Bypass -File scripts/dummy_attack_demo.ps1` → `DUMMY ATTACK DEMO OK`
  - `powershell -ExecutionPolicy Bypass -File scripts/heal_wounded_demo.ps1` → `HEAL WOUNDED DEMO OK`
- Do **not** drive `scripts/tab_combat_demo.ps1` — fail-closed stub (ARM-290).

Evidence lands per harness under its `-OutDir`. Default proof is DEMO + GAMELOG;
PNGs are artifacts only (ARM-289).

## Gotchas

- **Friendly must be wounded.** Heal on MaxHP spends mana but does not raise HP.
  `heal_wounded_demo.ps1` passes `-friendly-hp 50` to marqued.
- **Mage kit is admin `/give`.** Harnesses start marqued with `-admin`; the client
  grants cloth + staff after join. Do not pass a `-join-kit` mage forest.
- **Practice dummy, not last hostile.** Join worlds also spawn imps. Target
  selection filters `kind == dummy`.
- **Left-click is not attack.** The attack unit must right-click.
- **Close in before hostile right-click.** Under llvmpipe, probe until
  `GroundPicker` names the hostile practice dummy before firing.
