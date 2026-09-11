# 0007. Map identity (client/server agreement)

## Status

Accepted (M14c / ARM-255).

## Context

Ring of Trials is a second playable space beside the starter village. Spawn, world bounds, and (later) navmesh height must match the authored arena. Clients and servers need a shared name for "which map is active" without reviving a monolithic protocol doc.

## Decision

1. **Shared id string.** The active map is named by a stable id. Ring of Trials is `arena_ring_of_trials`. The village default is `village`. The id matches client asset/scene stems (`arena_ring_of_trials.glb`, `arena_ring_of_trials.tscn`) and, when present, shared export ids (see ADR 0006 nav JSON `id`).
2. **Operator selects both sides.** Server: `marqued -map <id>` (default `village`). Client play path (M14b / ARM-254) selects the matching scene by the same id. There is no client→server map pick intent in M14c.
3. **Welcome restates.** `welcome.map` carries the server's active id. The client may refuse or warn on mismatch with its loaded scene; it must not invent a different map from local preference alone while connected.
4. **Bounds and spawn follow the map.** Village keeps `HalfExtent = 128` and spawn `(0, 0, 0)`. Arena uses the playable XZ half-extent derived from the arena navmesh AABB (`ArenaHalfExtent`) and join/respawn on the arena floor (`ArenaFloorY` at origin XZ). Pose authority is unchanged: clients send wish only.

## Consequences

- Village defaults stay unless `-map arena_ring_of_trials` is set.
- M14d/e may replace flat `GroundY` with navmesh `HeightAt` without changing the map id contract.
- Do not encode map catalogs in `PROTOCOL.md`; keep the id table in code (`MapConfig`) and this ADR.

## Non-goals

- Wire negotiation or client-authored map switches.
- Multi-map instances in one process.
- Changing movement authority (ADR 0001).
