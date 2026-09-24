# 0002. Sim tick rate and cast wall-clock

## Status

Accepted (M13b). Implements the default tick locked by `docs/adr/0001-movement-authority.md`.

## Decision

1. **`TickDuration = 40 ms` (25 Hz)** in `server/internal/game/world.go`. It remains the only authority period. `welcome.tick_ms` is `TickDuration.Milliseconds()`. Do not add a second clock.
2. **Cast grace.** `CastGraceTicks = 8` (**320 ms** at 40 ms). Walk interrupts a pending cast only when remaining cast time is strictly greater than this grace.
3. **Ability cast and cooldown (wall-clock at 40 ms)** in `shared/abilities.json`:
   - Fireball `cast_ticks: 38` → **1520 ms**
   - Fireball `cooldown_ticks: 75` → **3000 ms**
   - Heal `cooldown_ticks: 38` → **1520 ms**
4. **Cooldown enforcement.** `cooldown_ticks` is enforced per ability by the server. A successful resolve starts the cooldown; cancellation does not. `welcome.cooldowns` resyncs remaining ticks and a resolve carries the catalog cooldown. There is no global cooldown.
5. **Heartbeat.** `HeartbeatEveryTicks = 10` is unchanged here. Client liveness stays `3 × heartbeat_ticks × tick_ms` (1200 ms at the new tick). Period retune is deferred.

## Out of scope

Attack period, gather duration, node respawn, and mana regen still use pre-40 ms tick counts and therefore run faster in wall time. Camp timers are documented in ADR-0015. Movement sample wire, jump, and prediction stay later M13 units.
