# 0015. Camp spawn spacing

## Status

Accepted (Combat MVP).

## Context

Imps spawn in a camp near the starter town. Without spacing rules, multiple imps can overlap at the same home point, which looks broken and makes targeting hard.

## Decision

1. **Camp definition.** A camp is a center point + radius + kind + pool max. The starter-town imp camp is authored in `server/internal/game/camp.go` as `StarterTownImpCamp` (`CampStarterTownImps`).
2. **Member placement.** Each camp member's home is placed by rejection sampling inside the camp radius. A placement is accepted only when its distance to every existing live camp member's home is at least `MinSpacing`.
3. **Phase offset.** To prevent imps from idling and wandering in lockstep, each newly spawned imp adds `index * ImpCampPhaseStrideTicks` to its first idle dwell. The first imp starts immediately; later imps stagger by 12 ticks each.
4. **Respawn.** When an imp dies it is despawned and its camp schedules a respawn after `DeathTimerTicks` plus a random `JitterTicks` offset. The respawn goes through the same placement and spacing rules.
5. **Validation.** `seedCamp` rejects a camp whose pool cannot physically fit inside its radius at the requested min spacing (disk-packing check).

## Consequences

- `server/internal/game/camp.go` owns camp logic.
- Tests assert spacing, respawn scheduling, and phase stride.

## Non-goals

- Dynamic camp creation or removal at runtime.
- Camp members wandering outside the camp radius.
- Multiple camps or camp chaining.
