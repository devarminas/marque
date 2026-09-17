# 0016. Primary stats and derived combat values

## Status

Accepted (Combat MVP).

## Context

Combat MVP needs attribute-driven damage so that different NPC archetypes and future player builds feel distinct. Four primary stats feed into derived combat values.

## Decision

1. **Primary stats.** `STR`, `DEX`, `CON`, `INT`. Baseline for players is 10. NPC values come from the archetype JSON (ADR-0017).
2. **Derived formulas.** All integer division truncates toward zero.
   - `MaxHP = 10 * CON` (min 1).
   - `MaxMana = 10 * INT` (min 0).
   - `AP = (STR - 10) / 2` (may be negative; subtracted from rolled damage before armor).
   - `SP = (INT - 10) / 2` (may be negative; added to ability effect amount with a floor of 1).
   - `Armor = max(0, (DEX - 10) / 2)` (subtracted from incoming white damage; hit floor 1).
   - `CritChance = max(0, DEX - 10)` (percent chance to double white damage before armor).
3. **Validation.** The archetype parser enforces `max_hp == 10 * con` so the JSON is not a second HP formula.
4. **Application.** White damage uses `AP`, `CritChance`, and `Armor` (ADR-0014). Ability damage adds `SP`.

## Consequences

- `server/internal/game/stats.go` owns the struct and derived methods.
- `server/internal/npcdef/npcdef.go` validates the archetype invariant.

## Non-goals

- Player character creation or level-up stat allocation.
- Resistance schools, dodge, or parry.
- Regeneration rates derived from stats.
