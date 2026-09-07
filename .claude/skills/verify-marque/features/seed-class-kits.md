# Seed class kits on the ground

M7g demo affordance: start marqued with `-seed-class-kits` so every unique
wearable kind from `shared/sets.json` (armor slots and tools) lies on the ground
near spawn. A player picks them up and equips a full class. `DefaultJoinKit`
stays empty.

## Sub-features

- `seed-class-kits-flag` — marqued accepts `-seed-class-kits`; `server_started`
  carries `seed_class_kits: true` and a `class_kit_seeds` list of `{kind,x,z}`.
- `seed-class-kits-kinds` — GAMELOG `item_spawned` lines cover every sets-derived
  wearable kind exactly once (same source as Wearables; join kit unchanged).
- `seed-class-kits-grid` — positions sit on a grid near origin: one Z row per
  sorted set id, kinds spaced 1.5 along X from `(1, 2)`.

## How to get to it (user POV)

- Launch the server with `-seed-class-kits`. Walk near spawn, pick up a set's
  pieces, equip them. The class restatement activates when the Requires map is
  complete. Optional `-item` seeds still work and append after the class-kit
  grid.

## Driving it with scripts/seed_class_kits_demo.ps1

Preconditions:

- `DOCTOR OK` is not required; this harness is server-only.
- Run `powershell -ExecutionPolicy Bypass -File scripts/seed_class_kits_demo.ps1`.
- Marker: `SEED CLASS KITS DEMO OK` on the **last line** of stdout. Exit code
  must also be 0.

The script builds marqued, starts it with `-seed-class-kits` on a free port,
reads `server_started` and `item_spawned` from stdout, and asserts the seeded
kinds match `game.ClassKitSeeds` expectations (non-empty, unique, join kit
empty in the started event).

Evidence lands in `-OutDir`, default `$env:TEMP\marque-seed-class-kits`:
`server.stdout.ndjson` and `server.stderr.log`.

## Gotchas

- **Empty join kit.** Class gear is not bag-seeded at join. Proof must use ground
  pickup, not a patched `DefaultJoinKit`.
- **Sets are the source.** Kinds come from `SetIDs` / `GetSet` (slots + tools),
  not from inventing kinds off class Requires alone.
- **Grid layout.** Origin `(1, 2)`, Δx `1.5`, Δz `2.0`, set ids sorted
  alphabetically. Documented in `game.ClassKitSeeds`.
- **Combines with `-item`.** Class-kit seeds prepend; repeated `-item` flags
  append to the same seeding loop.
