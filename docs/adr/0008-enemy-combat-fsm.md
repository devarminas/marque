# 0008. Enemy combat state machine

## Status

Accepted (Enemy combat v1 / ARM-261).

## Context

Imp AI used three tick phases (`idle` patrol, `combat` chase-and-swing, `return` leash). Combat swung on a continuous period while the target stayed in range. That shape cannot host Think, Kite, or later shared ability casts (ARM-262). Hard leash to spawn (`ImpLeashRange`) already works and stays.

## Decision

1. **Explicit FSM on the tick loop.** Hostile mobile NPCs (imps) advance one combat brain per tick inside the single game-state goroutine. States are `Patrol`, `Aggro`, `Approach`, `Attack`, `Think`, `Kite`, and `Return`.
2. **Happy path.** `Patrol` → proximity aggro → `Aggro` (log + lock target) → `Approach` → `Attack` (one swing gated by attack period) → `Think` → choose `Attack` or `Kite` → repeat. Out of melee range from `Attack`/`Think` returns to `Approach`.
3. **De-aggro.** Leaving `ImpLeashRange` from home, or losing a living target, enters `Return` and clears the target. Arriving home restores `Patrol`. Hard leash is the only de-aggro rule in v1.
4. **Attack gating.** Damage resolves only in `Attack` after the swing period. `Think` must complete before the next `Attack`. Being in range alone does not swing.
5. **Kite.** `Think` may select `Kite`: path away from the target while staying inside the leash, then re-enter `Think`. Skill casts are out of scope (ARM-262).
6. **Authority.** Server owns state and damage. Client renders `path` / HP / death facts only.

## Consequences

- `phaseIdle` / `phaseCombat` rename into the FSM constants above.
- Tests assert leash, transition order, and Think-gated swings.
- Weapon-def periods (ARM-265) plug into `Attack` without changing state names.

## Non-goals

- Enemy casts of shared player ability IDs (ARM-262).
- Threat tables, taunt, or sticky threat.
- Client-authored damage or aggro.
- Changing hard-leash semantics beyond keeping distance-to-home as the break.
