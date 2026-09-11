# WASD / direction `move` (wish + pose)

The local player holds a direction chord; the client sends `move` intents with
world-space `dx`/`dz`; the server steers at `WalkSpeed` and broadcasts `pose`.
WASD is the only player movement gesture. Player `path` / polyline walk is
retired (ARM-239). NPC `path` may remain.

## Sub-features

- Direction steer via `move` (sticky until zero or superseded)
- Camera-relative WASD → world axes on the client
- Attack cancel with `attack_cancelled.cause` = `move`
- Player `move_to` / player `path` are retired; UI left-click on bare ground
  sends nothing

## How to get to it (user POV)

1. Connect a windowed client to a live marqued.
2. Hold W/A/S/D. The avatar walks under server poses.
3. Left-click bare ground. Nothing walks; steer stays as it was.

## Driving it with verify-marque / scripts

From the repo root:

```powershell
powershell -File scripts/wasd_demo.ps1
```

Required markers: exit 0, last line `WASD DEMO OK`, client `DEMO done`,
`DEMO move_displacement` ≥ 1.5, GAMELOG `move` and pose progress (no player
`path_assigned`).

Proof map:

- Displacement: `DEMO pos` + `DEMO move_displacement` and GAMELOG `move` / pose
- Authority: Go `TestClientCannotAuthorPositionViaMove`
- Cancel: Go `TestMoveCancelsPendingAttack`
- Ownership: Go last-intent move-over-approach (sticky steer)

Full M13 action-movement e2e polish is ARM-241 (`features/polish/`).

## Gotchas

- Headless Godot draws nothing useful; the harness still needs a desktop session
  for screenshots, but displacement is proven from `DEMO pos` lines.
- Do not pipe the harness; redirect only.
- Fresh worktrees need `godot --headless --path client --editor --quit` once.
