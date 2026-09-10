# 0002. Sim tick rate and cast wall-clock

## Status

Accepted (M13b / ARM-234). Implements the default tick locked by `docs/adr/0001-movement-authority.md`.

## Decision

1. **`TickDuration = 40 ms` (25 Hz)** in `server/internal/game/world.go`. It remains the only authority period. `welcome.tick_ms` is `TickDuration.Milliseconds()`. Do not add a second clock.
2. **Cast grace.** `CastGraceTicks = 8` (**320 ms** at 40 ms). Walk interrupts a pending cast only when remaining cast time is strictly greater than this grace.
3. **Ability cast and cooldown (wall-clock at 40 ms)** in `shared/abilities.json`:
   - Fireball `cast_ticks: 30` → **1200 ms**
   - Fireball `cooldown_ticks: 30` → **1200 ms**
   - Heal `cooldown_ticks: 38` → **1520 ms**
4. **Heartbeat.** `HeartbeatEveryTicks = 10` is unchanged here. Client liveness stays `3 × heartbeat_ticks × tick_ms` (1200 ms at the new tick). Period retune is ARM-242.

## Out of scope

Attack period, gather duration, node respawn, camp timers, and mana regen still use pre-40 ms tick counts and therefore run faster in wall time (ARM-246). Movement sample wire, jump, and prediction stay later M13 units.
