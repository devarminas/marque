# 0009. Enemy combat state machine

## Status

Accepted (Enemy combat v1 / ARM-261).

## Context

Imp AI used three tick phases (`idle` patrol, `combat` chase-and-swing, `return` leash). Combat swung on a continuous period while the target stayed in range. That shape cannot host Think or later shared ability casts (ARM-262). Hard leash to spawn (`ImpLeashRange`) already works and stays.

## Decision

1. **Explicit FSM on the tick loop.** Hostile mobile NPCs (imps) advance one combat brain per tick inside the single game-state goroutine. States are `Patrol`, `Aggro`, `Approach`, `Attack`, `Think`, and `Return`.
2. **Happy path.** `Patrol` → proximity aggro → `Aggro` (log + lock target) → `Approach` → `Attack` (one swing gated by attack period) → `Think` → `Attack` again (or `Approach` if the target left melee) → repeat. Out of melee range from `Attack`/`Think` returns to `Approach` so the enemy closes distance when the player kites away.
3. **De-aggro.** Leaving `ImpLeashRange` from home, or losing a living target, enters `Return` and clears the target. Arriving home restores `Patrol`. Hard leash is the only de-aggro rule in v1.
4. **Attack gating.** Damage resolves only in `Attack` after the swing period. `Think` must complete before the next `Attack`. Being in range alone does not swing.
5. **No enemy kite.** Enemies do not path away from their target. Closing distance is always `Approach`. Skill casts are out of scope (ARM-262).
6. **Authority.** Server owns state and damage. Client renders `path` / HP / death facts only.

## Consequences

- `phaseIdle` / `phaseCombat` rename into the FSM constants above.
- Tests assert leash, transition order, Think-gated swings, and Approach when the target leaves melee.
- Weapon-def periods (ARM-265) plug into `Attack` without changing state names.

## Non-goals

- Enemy casts of shared player ability IDs (ARM-262).
- Threat tables, taunt, or sticky threat.
- Client-authored damage or aggro.
- Changing hard-leash semantics beyond keeping distance-to-home as the break.
