# 0009. Enemy combat state machine

## Status

Accepted (Combat MVP).

## Context

The pre-MVP imp AI used three tick phases (`idle` patrol, `combat` chase-and-swing, `return` leash). Combat MVP replaced that shape with a six-state FSM that hosts Think, white-damage swings, and shared ability casts in the same brain. Hard leash to spawn stays.

## Decision

1. **Explicit FSM on the tick loop.** Hostile mobile NPCs (imps) advance one combat brain per tick inside the single game-state goroutine. States are `Idle`, `Wander`, `Chase`, `Combat`, `Return`, and `Dead`.
2. **Idle.** The imp dwells for a random tick count drawn from the archetype `idle_min_ticks` / `idle_max_ticks`, then transitions to `Wander`.
3. **Wander.** The imp picks a random destination within the archetype `wander` radius of home, paths there, and returns to `Idle` on arrival. If the destination is too close it dwells in `Idle` instead.
4. **Chase.** When a living player enters the archetype `threat` radius the imp aggros: it sets the player as `attackTarget`, broadcasts `npc_aggro`, and paths toward the player. On reaching melee range (`AttackRange`) it transitions to `Combat`.
5. **Combat beats.** `Combat` cycles through three beats rather than a single continuous swing.
   - `Swing` — gates one white-damage hit by the weapon's `attack_period_ticks` (from `shared/weapons.json`). Damage uses the attacker's and target's primary attributes (ADR-0017). After a hit the beat becomes `Think`.
   - `Think` — lasts `ImpThinkTicks` (2 ticks). When Think completes the AI decides the next beat. If `thinkCount` is a multiple of `ImpCastEvery` (2) and the archetype skill is in range, the beat becomes `Cast`. Otherwise, if the target is still in melee range the beat becomes `Swing`; if the target has kited away the state returns to `Chase`.
   - `Cast` — the imp begins a timed ability via the shared cast runner (ADR-0011). While casting, `Combat` waits. When the cast resolves or cancels the beat returns to `Think`.
6. **Return (leash).** Leaving the archetype `leash` radius from home, or losing a living target, enters `Return`. The imp paths home. Arriving home snaps to spawn, clears the target, cancels any pending cast, resets combat progress, heals to full HP, and restores `Idle`.
7. **Dead.** When an imp's HP reaches zero it enters `Dead`, is despawned, and its camp schedules a respawn (ADR-0016).
8. **Authority.** Server owns state and damage. Client renders `path`, `hp`, `swing`, and `cast_phase` facts only.

## Consequences

- `server/internal/game/imp.go` is the single source of truth for transitions.
- Tests assert leash, idle→wander→idle cycles, Chase→Combat at range, Think-gated swings, and cast beats.

## Non-goals

- Threat tables, taunt, or sticky threat.
- Client-authored damage or aggro.
- Flee, CallHelp, or enemy kite behavior.
- Changing hard-leash semantics beyond distance-to-home as the break.
