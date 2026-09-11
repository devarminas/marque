# 0005. Ability locomotion policy

## Status

Accepted (M13f / ARM-238). Implements the ability locomotion hooks locked by `docs/adr/0001-movement-authority.md` §16. Cast grace wall-clock stays as locked by `docs/adr/0002-sim-tick-and-cast-timing.md`.

## Decision

1. **One policy per ability.** Shared ability defs carry a required `locomotion` string. Allowed values:

| Policy | While the ability is active |
|---|---|
| `movable` | Non-zero wish still integrates. Cast does not cancel on walk. |
| `rooted` | Non-zero wish is treated as zero (no steer). Cast does not cancel on walk. |
| `interrupt_on_move` | Non-zero wish cancels the pending cast unless remaining cast time is within grace. |

2. **Grace.** Unchanged: `CastGraceTicks = 8` (**320 ms** at 40 ms). Walk interrupts an `interrupt_on_move` cast only when `castTotal - castProgress > CastGraceTicks`.

3. **Instant casts.** Abilities with `cast_ticks` omitted or `0` resolve in the same handler turn. They never enter pending cast state, so walk cannot interrupt them. Ship them as `movable` unless a later unit needs a different feel.

4. **Catalog defaults (M13).**

| Ability | `locomotion` |
|---|---|
| `heal` | `movable` |
| `fireball` | `interrupt_on_move` |

5. **Authority.** Policy is server-owned. The client may mirror defs for UI later; it does not author locomotion facts. Abilities do not invent a second pose channel.

## Consequences

- `shared/abilities.json` and `server/internal/abilitydef` expose `locomotion`.
- Cast begin stores the policy on the pending cast. Move wish consults it before steer integrate and interrupt.
- A rooted ability may ship later; tests may use a catalog double until then.

## Non-goals

- New spell content.
- Animation graph polish.
- Jump gating by locomotion (may amend later).
- Player polyline retirement (ARM-239).
- PROTOCOL.md / NOTES.md.
