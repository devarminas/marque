# Gather then craft (contested tree)

The M4 milestone product: two players wear a lumberjack kit, race a tree for one
`logs` yield, and the winner crafts `logs`→`sticks`. The windowed contested
harness (`scripts/gather_craft_demo.ps1`) is **retired** (ARM-287 fail-closed
stub): it still expected bag kind `axe` under an empty `DefaultJoinKit` and was
never migrated to the wish+pose + `/give` verify path. Live gather proof uses
`gather_error_demo.ps1`; contested craft race needs a later migrate.

## Sub-features

- `equip-before-gather` — wear a matching lumberjack set and tool (GAMELOG
  `equip` / `class`). Live: `gather_error_demo.ps1` ground seeds + wear.
- `contested-gather` — exactly one `gather_resolved` and one `gather_lost` for
  the same node. **No live recipe** while the harness is quarantined; Go /
  GAMELOG store tests cover gather contest when needed.
- `craft-logs-to-sticks` — `use` with `from=logs` `to=sticks`. Product path
  remains; no live contested-race marker until a migrate.
- `demo-pass` — do **not** require `GATHER CRAFT DEMO OK`. Live gather marker is
  `GATHER ERROR DEMO OK` from `gather_error_demo.ps1`.

Minimum evidence:

| Claim | GAMELOG | DEMO | Pixel | Default rung |
|---|---|---|---|---|
| Live gather (wear + chop) | `gather_resolved`, `node_depleted` | gather DEMO | optional | live `gather_error` |
| Contested race + craft | n/a (harness retired) | n/a | n/a | **quarantined** ARM-287 |

## How to get to it (user POV)

- Press **I**, wear a full lumberjack set and `lumberjack_axe` from the bag (or
  ground seeds / admin `/give`). Right-click the tree; after the walk and chop
  duration, `logs` land in the bag and the tree depletes. Left-click the `logs`
  slot twice (use-on self) to craft `sticks`.

## Driving live gather (not gather_craft)

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/gather_error_demo.ps1`.
- Marker: `GATHER ERROR DEMO OK` on the **last line** of stdout. Exit code must
  also be 0.
- **Do not** treat `scripts/gather_craft_demo.ps1` as a proof. It is a
  fail-closed stub (ARM-287) that exits non-zero with a clear message.
  `--gather-craft-shots` / `gather_craft_demo.gd` are the same stub path.

## Gotchas

- **`GATHER CRAFT DEMO OK` is gone.** Recipes that still cite it are stale. Point
  at `GATHER ERROR DEMO OK` for live gather, or a future migrated contested demo.
- **Empty join kit / stale kinds.** `DefaultJoinKit` is empty; there is no
  wearable kind `axe`. Gather needs class `lumberjack` with `lumberjack_axe`.
  Seed via ground `-item` (as `gather_error_demo` does) or `-admin` + `/give`.
- **Primary tree at (5, 0).** A second starter tree lives at (-5, 2). Decorative
  trees in `world_map` are not gather nodes.
- **Self-use only.** Craft is two left-clicks on the same `logs` slot
  (`on` equals `slot`). Do not invent a second recipe.
- **Tracked quarantine (ARM-287).** `gather_craft_demo` is fail-closed on
  purpose: empty `DefaultJoinKit` / stale `axe`+weapon asserts, never migrated
  to wish+pose + `/give`. Contested craft race needs a later migrate; live
  gather proof is `gather_error_demo.ps1`. Reason lives in this note and PR
  #191 — do not revive a committed `decisions.tsv`.
