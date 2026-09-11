# 0006. Arena navmesh collision and height

## Status

Accepted (M14d/e draft).

## Context

ADR 0004 integrates jump on flat ground at `y = 0`. The Ring of Trials arena is authored in Godot with a `NavigationMesh`. Players must walk on that floor and stop at walls without client-authored pose facts.

M14b (client play path / `main.tscn`) and M14f (client prediction against mesh height) are out of scope here.

## Decision

1. **Export.** The client NavigationMesh for the arena is exported to shared JSON at `shared/maps/arena_ring_of_trials_nav.json` (`id`, `agent_radius`, `vertices`, triangle `polygons`). The exporter is `client/tools/export_arena_nav_json.gd`.
2. **Server mesh.** Package `server/internal/navmesh` loads that JSON into a `Mesh` (`Vertices`, `Polys`). `HeightAt(x,z)` returns barycentric Y on the first containing XZ triangle. `Move(from,to)` returns `to` when on mesh, otherwise the last on-mesh point along the segment (or `from` when the segment never hits the mesh).
3. **Optional wiring.** `World` holds an optional `*navmesh.Mesh`. Nil keeps the legacy flat world: XZ clamp to `±WorldHalfExtent`, ground at `y = 0`. Tests and callers enable the arena with `World.SetNav`.
4. **Walk.** When nav is set, `stepSteer` still clamps to world bounds, then runs `nav.Move` so wish steering cannot leave the mesh. Grounded XZ steps snap `y` from `HeightAt`.
5. **Vertical.** `stepVertical` lands at ground height at `(x,z)`, not always `0`. Grounded means `y <= groundY + eps` with `vy <= 0`.
6. **Authority unchanged.** Clients still send wish `dx`/`dz` (and jump edge). The server still owns pose. Players do not follow server polylines or nav paths; the mesh only constrains the wish→pose integrator.

## Consequences

- ADR 0004 flat-ground landing applies only when `World.nav` is nil. Loaded arena nav amends ground height and walkability for that world.
- Predicting clients (M14f) must share the same mesh sampling rules or reconcile harder to server `y`.
- Re-export the JSON when the Godot NavigationMesh changes.

## Non-goals

- Wiring the client play path or `main.tscn` (M14b).
- Client prediction changes beyond this note (M14f).
- NPC pathfinding, agent radius inflation, or multi-mesh maps.
