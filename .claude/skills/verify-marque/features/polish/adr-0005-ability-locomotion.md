# Polish ADR 0005 — Ability locomotion

Abilities attach `movable` / `rooted` / `interrupt_on_move` policy to the same
pose integrator. Catalog defaults: heal movable, fireball interrupt_on_move.
Wire/policy is Go; no prop mock claim.

## Sub-features

- `catalog-locomotion` — shared defs require a known `locomotion` string
- `interrupt-grace` — fireball walk cancels outside grace, survives inside
- `movable-while-cast` — heal (movable) resolves while walking
- `rooted-wish-zero` — rooted cast ignores non-zero wish

## How to get to it (user POV)

Start fireball, walk early → cast cancels. Heal while walking → cast completes.
No second pose channel from abilities.

## Driving it with Go

```bash
cd server && CGO_ENABLED=1 go test -race ./internal/abilitydef/ -run 'TestLoadSharedStarterAbilities|TestUnknownLocomotionFailsClosed|TestMissingLocomotionFailsClosed'
cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestFireballWalkInterruptsOutsideGrace|TestFireballGraceSurvivesWalk|TestMovableCastResolvesWhileWalking|TestRootedCastIgnoresWish|TestInstantCastIgnoresWalkInterrupt'
```

Existing live cast demos (`craft_cast_demo.ps1`, `dummy_cast_demo.ps1`,
`tab_combat_demo.ps1`) remain optional evidence; do not add a new demo for this
ADR. Prop mock does not cover locomotion policy.

## Gotchas

- Grace wall-clock is ADR 0002 (`CastGraceTicks = 8`). Do not re-derive ticks in
  a client mock.
- Policy is server-owned; client may mirror defs for UI later.
