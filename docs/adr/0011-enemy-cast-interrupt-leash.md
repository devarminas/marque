# 0011. Enemy cast interrupt and leash

## Status

Accepted (Enemy combat v1 / ARM-262).

## Context

Enemies cast shared player ability IDs through the combatant cast runner (ARM-266). Player casts already honor locomotion (`movable` / `rooted` / `interrupt_on_move` with `CastGraceTicks`). Hostile AI also hard-leashes home (`ImpLeashRange`). Enemy Think may enter CastSkill; leash and path locomotion must not leave a dangling cast.

## Decision

1. **Same effect path.** Enemy CastSkill starts an ability by catalog id via `World.castAbility`. Instant and `cast_ticks` resolve through the shared combatant apply path (HP, faction, range). No client `cast` intent is synthesized for enemies.
2. **CastSkill hold.** While casting a non-`movable` ability, the enemy halts path before begin. CastSkill waits until the cast clears, then returns to Think.
3. **Leash cancels cast.** Entering Return clears the pending cast immediately with cause `leash` (no grace). Hard leash still wins over an in-progress cast.
4. **Path move uses player interrupt policy.** When an enemy advances a path while casting `interrupt_on_move`, call the shared `interruptCastOnMove` (grace when remaining ≤ `CastGraceTicks`). `rooted` blocks path Advance for that caster until the cast ends.
5. **Skill pick.** Think may select CastSkill on a cadence (`ImpCastEvery`) using the shared player ability id (`ImpSkillID` = `fireball` in v1). If the target is out of melee, Think chooses `Approach` instead of Attack.

## Consequences

- Tests cover enemy fireball damaging a player through CastSkill, leash cancel mid-cast, and move interrupt of an enemy cast.
- Weapon-def periods and sticky AA stay out of this ADR.

## Non-goals

- Enemy-only ability kits or mana economy.
- Threat tables or sticky threat.
- Client cast UI for NPCs.
