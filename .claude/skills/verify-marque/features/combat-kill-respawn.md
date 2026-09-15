# Kill and respawn

M5 combat outcomes: period hits to death, death overlay, respawn to full HP, act
again. The two-client PvP windowed demo (`scripts/combat_demo.ps1`) is **retired**
(ARM-284 fail-closed stub; PvP attack refused since ARM-203). Live proof now uses
NPC demos; player death/respawn store rules stay on the Go rung.

## Sub-features

- `period-hits` — Go: ten `attack_hit` of damage 10 to death on an Imp
  (`TestTenHitsKillImpFromFull`). Live smoke: ≥1 `attack_hit` via
  `dummy_attack_demo.ps1`.
- `death-and-respawn` — Go: `death` then `respawn` restores HP 100 / clears walk
  (`TestRespawnRestoresAtJoinSpawn`, `TestDeadRefusesOrdinaryIntents`). No live
  PvP recipe.
- `act-after-respawn` — Go: post-respawn intents accepted; refused when not dead
  (`TestLivingRespawnRefused`).
- `live-melee-loop` — `dummy_attack_demo.ps1` covers right-click attack; combine
  with `dummy_cast` / `heal_wounded` / `wasd` for the former tab_combat claims
  (`DUMMY ATTACK DEMO OK`, `HEAL WOUNDED DEMO OK`, …).
- `demo-pass` — live markers are the focused-unit OK lines (ARM-290).
  `TAB COMBAT DEMO OK` / `COMBAT DEMO OK` are retired.

Minimum evidence:

| Claim | GAMELOG | DEMO | Pixel | Default rung |
|---|---|---|---|---|
| Period hits to kill | ten `attack_hit` dmg 10 → HP 0 (`TestTenHitsKillImpFromFull`, `TestAttackOutOfRangePathsInThenHitsOnPeriod`) | n/a | n/a | **Go** |
| Live NPC melee smoke | ≥1 `attack_hit` | attack DEMO | optional | live `dummy_attack` |
| Player death/respawn | `death`, `respawn`, HP 100 | n/a (no live PvP) | n/a | **Go** |
| Tab combat claims | `cast_effect`, `attack_hit`, `move` | fireball/heal/attack/move DEMO | optional | live focused units (ARM-290) |

## How to get to it (user POV)

- Right-click a hostile practice dummy: you path in and land period hits.
- Player death overlay and Respawn are still in the client UI; exercise them via
  Go when proving store rules. Do not run `combat_demo.ps1` for proof.

## Driving it with focused combat demos (not combat_demo / tab_combat)

Default driver rung by claim: **Go** for period-kill cadence and death/respawn;
**live** `scripts/dummy_attack_demo.ps1` for NPC melee smoke; **live**
`wasd` / `dummy_cast` / `heal_wounded` for the former M6i loop claims (ARM-290).

Preconditions:

- `DOCTOR OK`; desktop for live demos.
- NPC melee smoke: `powershell -ExecutionPolicy Bypass -File scripts/dummy_attack_demo.ps1`.
  Marker: `DUMMY ATTACK DEMO OK` last line; exit 0.
- Heal wounded: `powershell -ExecutionPolicy Bypass -File scripts/heal_wounded_demo.ps1`.
  Marker: `HEAL WOUNDED DEMO OK` last line; exit 0.
- Period hits + death/respawn store: from `server/`,
  `CGO_ENABLED=1 go test -race ./internal/game/ -run 'TenHitsKillImpFromFull|AttackOutOfRangePathsInThenHitsOnPeriod|DeadRefuses|RespawnRestores|LivingRespawn|GatheringPlayerStillDies'`.
- **Do not** treat `scripts/combat_demo.ps1` or `scripts/tab_combat_demo.ps1` as
  proofs. Both are fail-closed stubs (ARM-284 / ARM-290).

## Gotchas

- **`COMBAT DEMO OK` / `TAB COMBAT DEMO OK` are gone.** Recipes that still cite
  them are stale. Point at focused-unit markers / Go.
- **Left-click is not attack.** After M6c, demos must right-click (or call
  `request_attack`).
- **Roles / join order.** Resolve ids from `DEMO joined`, never from window labels.
- **Friendly dummy refuses.** See `right-click-basic-attack.md`.
