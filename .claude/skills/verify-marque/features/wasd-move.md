# WASD / direction `move` (M6g)

The local player holds a direction chord; the client sends `move` intents with
world-space `dx`/`dz`; the server steers at `WalkSpeed` and broadcasts short
`path` segments. WASD is the only player movement gesture (ARM-145 removed
ground-click `move_to` from the UI). `move_to` remains on the wire for demos
and probes; last intent wins when both hit the same tick.

## Sub-features

- Direction steer via `move` (sticky until zero or superseded)
- Camera-relative WASD → world axes on the client
- Attack cancel with `attack_cancelled.cause` = `move`
- Wire `move_to` still exists for scripted demos; UI left-click on bare ground
  sends nothing

## How to get to it (user POV)

1. Connect a windowed client to a live marqued.
2. Hold W/A/S/D. The avatar walks under server paths.
3. Left-click bare ground. Nothing walks; steer stays as it was.

## Driving it with verify-marque / scripts

From the repo root:

```powershell
powershell -File scripts/wasd_demo.ps1
```

Required markers: exit 0, last line `WASD DEMO OK`, client `DEMO done`,
`DEMO move_displacement` ≥ 1.5, GAMELOG `move` and `path_assigned`.

Proof map for ARM-114 ACs:

- AC1: `DEMO pos` + `DEMO move_displacement` and GAMELOG `path_assigned`
- AC2: Go `TestClientCannotAuthorPositionViaMove` (large `dx` still one WalkSpeed step)
- AC3: Go `TestMoveCancelsPendingAttack`
- AC4: Go `TestLastIntentWinsMoveAndMoveTo`

## Gotchas

- Headless Godot draws nothing useful; the harness still needs a desktop session
  for screenshots, but displacement is proven from `DEMO pos` lines.
- Do not pipe the harness; redirect only.
- Fresh worktrees need `godot --headless --path client --editor --quit` once.
