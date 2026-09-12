# 0008. Player in-combat state and nearest-player aggro

## Status

Accepted (Enemy combat v1 / ARM-267).

## Context

Players have no server in-combat / out-of-combat flag. Imp aggro walks `w.order` and takes the first living player in `ImpThreatRange`, so multi-player fights are join-order lottery. Hard leash to spawn (`ImpLeashRange`) already works and stays. Threat tables and taunt stay out of v1. ARM-261 may replace the enemy combat FSM later; this ADR does not rewrite it.

## Decision

1. **In-combat events.** A living player enters (or refreshes) combat when they deal damage, take damage, or gain enemy aggro. Healing alone does not. Practice-dummy damage counts as dealing damage.
2. **Timeout.** `CombatTimeoutTicks = int64(6 * time.Second / TickDuration)` (**6 s** at `TickDuration = 40 ms`). After that many ticks with no combat event, the player is out of combat. Document the wall-clock here; do not invent a second clock.
3. **Storage.** Server owns `combatExpiresTick` on the player (`0` = out of combat). `inCombat(tick)` is true when `combatExpiresTick > tick`. Each combat event sets `combatExpiresTick = tick + CombatTimeoutTicks`. Clear on death/respawn. Wire to the client only if UX needs it; v1 is server-authoritative and testable without a new frame.
4. **Aggro selection.** Idle hostile (imp) aggro picks the **nearest living player** within `ImpThreatRange`. Equal distance keeps join-order as a stable tie-break. Hard leash rule and `ImpLeashRange` stay unchanged.

## Consequences

- Two players in threat range: the closer one gets aggro, not the earlier joiner.
- In-combat is refreshable; continuous hits keep the flag set.
- ARM-261 may reshape enemy states; keep aggro selection and player combat timeout as small hooks, not a second combat brain.

## Non-goals

- Threat tables, taunt, or sticky threat.
- Replacing the imp idle/combat/return tick machine (ARM-261).
- Client UX chrome for the combat flag (deferred until needed).
