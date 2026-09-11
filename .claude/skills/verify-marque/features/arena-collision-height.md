# Arena collision and height (Ring of Trials)

On Ring of Trials, wish steering stops at navmesh walls, walks ramps at the
mesh height, and jumps land on local ground. Server pose owns authority;
client prediction mirrors the same mesh (ADR 0006 / M14f).

## Sub-features

- `wall-block` — steer into a solid; XZ stops on-mesh (`DEMO wall_blocked`)
- `ramp-height` — climb the authored ramp; avatar `y` rises (`DEMO ramp_rise`)
- `jump-land` — grounded jump rises then lands (`DEMO jump_peak_y` /
  `DEMO jump_land_y`); GAMELOG `move` with `jump: true`
- `arena-map` — marqued `-map arena_ring_of_trials` + client `--map arena` /
  `MARQUE_MAP=arena`

## How to get to it (user POV)

1. Start marqued with `-map arena_ring_of_trials`.
2. Start a windowed client with `MARQUE_MAP=arena` (or `--map arena`).
3. Walk into a wall — you stop. Walk a ramp — height changes. Jump — rise and
   land on the local floor.

## Driving it with verify-marque / scripts

From the repo root (needs a desktop session for screenshots):

```powershell
powershell -File scripts/arena_collision_demo.ps1
```

Required markers: exit 0, last line `ARENA COLLISION DEMO OK`, client
`DEMO done`, `DEMO wall_blocked`, `DEMO ramp_rise` ≥ 0.35, jump peak above
land, five `DEMO shot` PNGs >4KB, GAMELOG `map=arena_ring_of_trials`,
`move` with `jump: true`, and no player `path_assigned`.

Proof map:

- Wall / ramp / jump: client `DEMO` lines + PNGs under the harness `-OutDir`
- Authority: GAMELOG `move` (wish + jump edge); Go `TestNavSteerBlockedOffMesh`,
  `TestNavRampWalkChangesY`, `TestNavJumpLandsAtLocalGround`
- Prediction mirror: headless `test_local_mover_nav.gd`

## Gotchas

- Headless Godot does not prove pixels; the PS1 still needs a display for the
  five screenshots.
- Village / nil-nav is a different map; this recipe is arena-only.
- Do not pipe the harness; redirect only.
- Fresh worktrees need `godot --headless --path client --editor --quit` once.
