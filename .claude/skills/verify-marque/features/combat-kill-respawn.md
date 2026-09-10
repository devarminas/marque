# Kill and respawn

M5 combat outcomes: period hits to death, death overlay, respawn to full HP, act
again. The two-client PvP windowed demo (`scripts/combat_demo.ps1`) is **retired**
(ARM-203; PvP attack refused). Live proof now uses NPC demos; player death/respawn
store rules stay on the Go rung.

## Sub-features

- `period-hits` — Go: ten `attack_hit` of damage 10 to death on an Imp
  (`TestTenHitsKillImpFromFull`). Live smoke: ≥1 `attack_hit` via
  `dummy_attack_demo.ps1`.
- `death-and-respawn` — Go: `death` then `respawn` restores HP 100 / clears walk
  (`TestRespawnRestoresAtJoinSpawn`, `TestDeadRefusesOrdinaryIntents`). No live
  PvP recipe.
- `act-after-respawn` — Go: post-respawn intents accepted; refused when not dead
  (`TestLivingRespawnRefused`).
- `live-melee-loop` — `tab_combat_demo.ps1` covers right-click attack among cast
  and WASD (`TAB COMBAT DEMO OK`).
- `demo-pass` — live markers are `DUMMY ATTACK DEMO OK` or `TAB COMBAT DEMO OK`
  on the last line with exit 0. Never require `COMBAT DEMO OK`.

Minimum evidence:

| Claim | GAMELOG | DEMO | Pixel | Default rung |
|---|---|---|---|---|
| Period hits to kill | ten `attack_hit` dmg 10 → HP 0 (`TestTenHitsKillImpFromFull`, `TestAttackOutOfRangePathsInThenHitsOnPeriod`) | n/a | n/a | **Go** |
| Live NPC melee smoke | ≥1 `attack_hit` | attack DEMO | optional | live `dummy_attack` |
| Player death/respawn | `death`, `respawn`, HP 100 | n/a (no live PvP) | n/a | **Go** |
| Tab combat loop | `cast_effect`, `attack_hit`, `move` | fireball/heal/attack/move DEMO | optional | live `tab_combat` |

## How to get to it (user POV)

- Right-click a hostile practice dummy: you path in and land period hits.
- Player death overlay and Respawn are still in the client UI; exercise them via
  Go when proving store rules. Do not run `combat_demo.ps1` for proof.

## Driving it with dummy_attack / tab_combat (not combat_demo)

Default driver rung by claim: **Go** for period-kill cadence and death/respawn;
**live** `scripts/dummy_attack_demo.ps1` for NPC melee smoke; **live**
`scripts/tab_combat_demo.ps1` for the M6i loop.

Preconditions:

- `DOCTOR OK`; desktop for live demos.
- NPC melee smoke: `powershell -ExecutionPolicy Bypass -File scripts/dummy_attack_demo.ps1`.
  Marker: `DUMMY ATTACK DEMO OK` last line; exit 0.
- Combat loop: `powershell -ExecutionPolicy Bypass -File scripts/tab_combat_demo.ps1`.
  Marker: `TAB COMBAT DEMO OK` last line; exit 0.
- Period hits + death/respawn store: from `server/`,
  `CGO_ENABLED=1 go test -race ./internal/game/ -run 'TenHitsKillImpFromFull|AttackOutOfRangePathsInThenHitsOnPeriod|DeadRefuses|RespawnRestores|LivingRespawn|GatheringPlayerStillDies'`.
- **Do not** treat `scripts/combat_demo.ps1` as a proof. It is a stub that exits 0
  without a marker. Client `--combat-shots` wiring may still exist; the PS1 is what
  agents must not run for markers.

## Gotchas

- **`COMBAT DEMO OK` is gone.** Recipes that still cite it are stale. Point at
  `DUMMY ATTACK DEMO OK` / `TAB COMBAT DEMO OK` / Go.
- **Left-click is not attack.** After M6c, demos must right-click (or call
  `request_attack`).
- **Roles / join order.** Resolve ids from `DEMO joined`, never from window labels.
- **Friendly dummy refuses.** See `right-click-basic-attack.md`.
