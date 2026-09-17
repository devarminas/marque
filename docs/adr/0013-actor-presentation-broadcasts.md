# 0013. Actor presentation broadcasts

## Status

Accepted (Prototype art contract).

## Context

Every client animates every actor, players and imps alike, from server facts. Before this change the owner alone saw its own cast (`casting`) and its own gear (`equipment`). Observers saw `hp`, `path`, and `pose`, and nothing that says an actor swung, cast, or started to gather. The tick loop already computes each of those facts. It did not send them.

## Decision

1. **Four downlink messages.** The server broadcasts each one to every connected client.

   | Key | Body | Sent when |
   |---|---|---|
   | `swing` | `{id, target, weapon}` | A melee hit resolves: player on player, player on NPC, or imp on player. The server sends it before the `hp` broadcast for that hit. `weapon` is the attacker's weapon id from `shared/weapons.json`, or `unarmed`. |
   | `cast_phase` | `{id, ability, target, phase}` | `phase` is `begin` when a timed cast starts, `resolve` when an ability applies, and `cancel` when a pending cast ends without applying. Players and NPCs both send it. |
   | `gather` | `{id, node}` | A gather channel starts: the gatherer is in range and the first gather tick counts. |
   | `worn` | `{id, slots}` | A player equips or unequips. `slots` has the shape of `equipment.slots`. |

2. **`PlayerState.worn`.** Each entry of `welcome.players` and each `spawn` carries `worn`, so a client that joins late sees gear without waiting for a change.
3. **Every `begin` gets exactly one end.** After `cast_phase begin`, the same actor gets exactly one `resolve` or `cancel` for that cast. `closeCast` in `server/internal/game/cast.go` is the only function that clears a pending cast. Its two callers are `cancelCast`, which sends `cancel`, and `finishCast`, which hands the cast to `applyCast`, which sends `resolve`. A timed cast that fails a final check (ability missing from the catalog, target lost, target out of range, mana short) ends with `cancel`. Death, leash, move interrupt, replacement, and `killImp` all end through `cancelCast`.
4. **Instant abilities send `resolve` alone.** An ability with `cast_ticks: 0` never had a pending cast, so it has no `begin`. A player may cast an instant ability while a timed one is pending. An end therefore matches a `begin` by `id` and `ability`, and a `resolve` with no matching `begin` is an instant cast that leaves the pending one open.
5. **Presentation facts only.** These messages drive animation. Client game logic must not branch on them. HP, death, cast progress, and inventory keep their own messages, and those stay the source of truth.
6. **No catch-up for actions in flight.** A client that joins during a cast receives the `resolve` or `cancel` without its `begin`, and must accept an end with no start. The same holds for a swing or a gather already under way. `despawn` ends every presentation fact for its id.
7. **Derived facts stay derived.** A hit is a drop in `hp`. Death is `hp == 0`. A jump is a rise in pose `y`. The enemy FSM phase from ADR 0009 stays private.
8. **Owner-only messages are unchanged.** `equipment` and `casting` keep their shape and their single recipient.

## Consequences

- `server/internal/game/presentation_test.go` covers each emit site and the one-end rule for every cancel cause.
- A client older than the routing unit logs a warning for each new key and ignores it. `PlayerState.worn` is an extra field that the current parser does not read.

## Non-goals

- Client routing of these messages and the animation itself.
- Attack period, cast timing, or swing timing retunes.
- Talk or jump messages.
