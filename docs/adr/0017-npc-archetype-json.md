# 0017. NPC archetype JSON

## Status

Accepted (Combat MVP).

## Context

Imp behavior was hard-coded in Go constants (HP, threat range, weapon, skill). Combat MVP moved imp data to JSON so designers can tune without rebuilding the server.

## Decision

1. **`shared/npc_archetypes.json`.** The file contains an `archetypes` array. Each entry has:
   - `id` — catalog key (e.g. `imp`).
   - `max_hp`, `weapon_id`, `skills` — combat baseline.
   - `threat`, `leash`, `wander` — AI ranges in world units.
   - `idle_min_ticks`, `idle_max_ticks` — dwell distribution.
   - `str`, `dex`, `con`, `int` — primary stats (ADR-0016).
2. **Validation.** `server/internal/npcdef/npcdef.go` rejects:
   - Missing or duplicate ids.
   - Empty `weapon_id` or `skills`.
   - `wander >= leash`.
   - `max_hp != 10 * con`.
   - Any primary stat `< 1`.
3. **Runtime.** The world loads the catalog at startup. `seedNPCAt` looks up the `imp` archetype and copies its values into the NPC struct. If the catalog is missing the server refuses to seed imps.
4. **Required archetype.** The catalog must contain an `imp` entry. Other archetypes are optional.

## Consequences

- Tuning imp HP, weapon, threat range, or idle timing is a JSON edit.
- Tests use `IncompleteCatalog` to exercise validation without requiring the full file.

## Non-goals

- Hot-reloading archetypes at runtime.
- Per-camp archetype overrides.
- Archetype inheritance or composition.
