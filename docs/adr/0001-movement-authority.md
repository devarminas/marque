# 0001. Movement authority

## Status

Accepted (M13a / ARM-233). Binding for M13. M13g (ARM-239) retired player polyline locomotion; NPC path exception remains.

## Context

Players move with WASD. The live stack still treats locomotion as sticky `move` intents plus server-assigned `path` polylines at `TickDuration = 150 ms` (`server/internal/game/world.go`). The client walks those polylines. That shape made click-to-move and sparse ticks workable. It fights continuous steering, jump, melee-while-walking, and client prediction.

`AGENTS.md` already dropped polyline walking as an invariant. The replacement authority model was not written down. Milestone M13 Action movement requires server-owned pose at roughly 25 Hz with client prediction, jump, ability locomotion hooks, and retirement of player polylines.

This ADR decides movement authority only. Global invariants stay in `AGENTS.md`. Other systems (inventory, equipment, dupes) get their own ADRs when they change.

Out of scope for this ADR: navmesh, client-authored positions, and shipping the movement code (M13b–h).

## Decision

### Authority

1. The client sends **movement inputs**, never pose facts. A movement sample carries a ground-plane wish direction (`dx`/`dz` in world axes; camera converted on the client, as today) and a jump edge (pressed this sample or not). It does not carry position, velocity, or airborne height as claims about the world. Wish direction stays continuous floats. Do not quantize to octants.
2. The server **integrates** those inputs each tick, clamps and resolves collisions it owns, and stores the authoritative player pose `(x, y, z)` plus whatever locomotion flags later units need (for example grounded, rooted, airborne).
3. The owning client **predicts** locally with the same integration rules it can know, renders the predicted pose, and **reconciles** when a server pose arrives. On conflict, the server pose wins. Soft correction is allowed. Hard snap is allowed when error exceeds a named threshold later units pick. Remote clients render from server pose only (interpolation allowed; no remote prediction required in M13).
4. **Illegal samples.** Refuse at the wire boundary, before game handlers run, any client→server movement body that asserts player locomotion facts. Named refusal: `illegal_sample` (or the project's existing malformed-intent error shape carrying that message). Denylist keys for movement intents include `x`, `z`, `y`, `pos`, `position`, `pose`, `path`, `velocity`, `vx`, `vz`, `vy` (and clear aliases). Non-finite wish components are refused the same way. Do not apply the body. Log it. Keep the connection. Scope the denylist to movement intents; do not ban those keys from unrelated messages.
5. Movement integration runs inside the existing tick step on the game-state owner. This ADR does not add a second simulation loop.

### Tick

6. One simulation clock. `TickDuration` stays the only authority period. Default **25 Hz / 40 ms**. Implementers may tune inside **20–30 Hz** without a new ADR if cast grace and heartbeat math stay expressed in wall-clock ms. Do not add a second movement clock.
7. Amend the old 150 ms law. Continuous WASD with prediction needs denser samples than polyline interpolation needed. Cast and heartbeat tick counts retune to keep wall-clock feel (M13b / ARM-234).

### Wire shape (sketch; M13c names exact JSON)

8. Client→server movement replaces sticky polyline-driving `move` as the player locomotion intent. Sketch: wish `dx`/`dz` plus `jump` edge. Samples may repeat while keys are held. About one sample per tick is enough. Holding a key is still not a reason to claim a world position.
9. Server→client player locomotion broadcasts **pose** (or an equivalent restatement that includes pose), not player `path` polylines. Sketch: player id, tick, `x`, `y`, `z`, and any small locomotion flags needed to reconcile. Waypoint lists are not how players move. Broadcast pose when the player moves or locomotion flags change, and **at least once per second while idle** so late joiners and reconciliation keep an anchor.
10. `welcome` and late-join restatements carry the same pose fields the live pose channel uses. No separate in-flight polyline replay for players.

### Jump and `y`

11. Jump is a **server-resolved** response to a jump edge on a legal grounded (or otherwise allowed) pose. Jump stays a **movement input edge** under the same integrator, not a standalone ability type in M13. The client may predict the jump. It may not dictate landing position.
12. Amend "y never appears on the wire." Player **pose** messages include `y` because vertical motion is now a game rule, not only scenery. Ground wish stays `(x, z)`. Map authoring may still treat most of the world as a height field. Bridges-you-can-walk-under remain a later problem. This ADR does not design navmesh.

### Player `move_to` and `path`

13. Player **`move_to` dies** for production play. The live Godot client must not send it. When M13 wire work lands, the server refuses player `move_to` (or stops parsing it for players). Scripted demos and headless drivers that need locomotion send the same movement-sample inputs, or drive pose only through server-side test hooks. They do not reintroduce destination facts on the player wire.
14. Player **`path` polylines retire** for locomotion (M13g). Pickup, gather, and similar "get near this id" flows become server-side approach goals resolved by the same pose integrator, or stay as range checks without a client-visible polyline. Exact approach AI is a later unit. The invariant is that players never advance by walking a broadcast polyline.
15. **NPC** `path` / polyline walking may remain. NPCs are not under the player prediction contract in M13.

### Ability locomotion (hook only)

16. Abilities do not invent a second movement authority. They attach to locomotion policy on the mover. Server locomotion state is readable on the tick that resolves combat.

| Hook | Feel | Default use |
|---|---|---|
| **movable** | Wish still integrates while the ability runs | Melee |
| **rooted** | Wish ignored (treated as zero) while the ability runs | Channeled / heavy cast |
| **interrupt_on_move** + grace | Non-zero wish cancels the ability unless remaining cast time is within grace ticks | Standard cast (retune grace for 40 ms) |

M13 locks these hooks and the melee-movable / cast-cancel-or-root defaults. Map them onto existing cast interrupt and `CastGraceTicks` behavior in M13f. Do not design the full ability catalog here.

## Consequences

- `AGENTS.md` carries durable movement bullets that match this ADR.
- M13b raises `TickDuration` into the locked band and retunes cast/heartbeat math in wall-clock ms.
- M13c–d replace player `move`+`path` with input samples and pose restatements, and teach the client to predict and reconcile.
- M13e adds jump against server pose including `y`.
- M13f hooks abilities into the locomotion policy table above.
- M13g (ARM-239) retires player polyline locomotion end-to-end: the server does not assign or broadcast player `path` for WASD, halt, or approach (gather/talk/attack/pickup). Out-of-range interact uses sticky steer toward the target via the pose integrator; in-range is a range check only. NPC `path` / polyline walking remains (Imp chase/patrol). Player `arrived` from path completion is gone; NPC `arrived` stays.
- M13h demos prove WASD, jump, and no player polyline on the wire.
- Exact movement JSON names are settled in `docs/adr/0003-movement-wire.md`. Wire details land in code and tests. New mechanic polish lands in new ADRs. Do not revive a monolithic protocol or notes file.

## Non-goals

- Client-authoritative or client-sampled positions on the wire.
- Navmesh or building collision.
- Decisions for other systems (inventory, equipment, dupes). Those get their own ADRs.
- Forcing NPC locomotion onto the player pose channel in M13.
- Octant or otherwise quantized wish direction as the M13 uplink.
- Deriving authoritative `y` client-side from an airborne flag alone.
