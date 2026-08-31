# Game Notes

Game: RuneScape-like point-and-click farming/crafting, multiplayer, persistent inventory.
Client: Godot 4.x, GDScript. Server: Go. Single server for now.
Nothing installed yet — `winget install GodotEngine.GodotEngine`

## Headless testing

```bash
godot --headless --path . --script res://tests/run_tests.gd
```

- No rendering server. Logic, physics, signals, resources all run.
- `print()` → stdout. `quit(1)` → exit code. `--quit-after N` bounds runaway loops.
- Test framework: GdUnit4 (check it supports the Godot version before committing).
- Anything visual (shaders, viewport textures) does not work headless.
- Visual checks: game screenshots itself, don't automate the desktop.
  `get_viewport().get_texture().get_image().save_png("user://shot.png")`

## JSON mode

Autoload singleton, everything emits through it. NDJSON to stdout, one object per line:

```
GAMELOG {"t":142,"ev":"damage","src":"enemy_3","dst":"player","amt":12,"hp_after":68}
```

- Prefix tag so engine warnings can be grepped out.
- `t` = frame number, not wall-clock. Wall-clock makes every run diff differently.
- Gate behind `--json-log` / env var so release builds pay nothing.

### Scripted input (the other half)

Log alone = observe only. Add a JSON input channel to drive the game:

```json
[{"t":0,"action":"move_right"},{"t":30,"action":"jump"}]
```

Run scenario headless → diff event log vs expected. That's a gameplay regression test.

### Determinism — precondition for all of the above

- Seeded `RandomNumberGenerator` per system, no global rand.
- Fixed timestep (`--fixed-fps`).
- No wall-clock reads in game logic.

Without this two identical runs produce different logs and every diff is noise.

## Color as semantics, not decoration

Flat unlit materials, fixed palette:

| Color | Meaning |
|---|---|
| Magenta | Missing asset — loud failure |
| Red | Hostile |
| Blue | Player / friendly |
| Yellow | Interactable |
| Green | Pickup |
| Orange | Hazard / trigger volume |
| Gray | Static world geometry |

- Magenta-for-missing is the important one. Missing model should scream, not render nothing.
- Readable from a screenshot at a glance — by me and by an agent reading a captured PNG.
- Pair with a world-space checker material (1m squares, driven by world pos, no UVs) so scale is readable on untextured primitives.

## Backend — Go

No physics to share with the client, so no reason to run Godot on the server.
The game is a database with a game attached; Go has the ecosystem for that (pgx).

| Piece | What | Owns |
|---|---|---|
| Client | Godot / GDScript | Render, input, interpolation. Zero authority. |
| Server | Go | Tick loop, all state in memory, all validation |
| DB | Postgres | Durable state, written transactionally |
| Transport | WebSocket | Godot `WebSocketPeer` ↔ Go |

- Client sends **intents**, never facts. `{"use":{"slot":3,"on":7}}`, never `{"inventory":[...]}`.
- Client inventory is a cache of what the server last said.
- Shared data (items, recipes, XP tables, map) = JSON in one folder, read by both. One source of truth, two languages.

## Movement — client sends click, server returns polyline

```
→ {"move_to":{"x":42.3,"y":17.8}}
← {"path":[[10.0,4.0],[14.2,6.1],[42.3,17.8]],"speed":3.0}
```

- Pathfinding lives **only on the server**. No client pathfinder, no duplication, no divergence.
- Client walks the polyline and interpolates → smooth movement regardless of tick rate.
- Cost is one round trip before the character moves. Reads as normal for click-to-move.
- Send waypoints, not per-tick positions.
- Server validates the destination is reachable. Reject unreachable clicks, don't silently snap to nearest.
- Optional later: client paths cosmetically with Godot's `NavigationServer` for instant response, reconciles when server path lands. Only if the round trip feels bad.

### Navmesh pipeline

Bake in the Godot editor → export vertices/polygons as JSON → Go loads at boot.

```json
{"vertices":[[0,0],[4,0],[4,4]], "polygons":[[0,1,2]], "hash":"a3f9..."}
```

- A* over polygon adjacency + funnel string-pulling. A few hundred lines of Go.
- Don't need Detour's full feature set (tile streaming, off-mesh links, crowd avoidance) — mostly-flat ground with static obstacles.
- **Hash the mesh, ship it in both builds, server refuses to boot on mismatch.** Stale mesh = players walk through walls and it looks like a gameplay bug, not a build bug.
- Make the export a build step. Anything manual gets skipped.
- Unverified: that `NavigationMesh` vertex/polygon export round-trips cleanly. Check before designing the map format around it.

## Tick rate

- Tick rate and movement smoothness are independent. Client interpolation handles smoothness.
- Fast ticks are only needed when sub-tick position changes a game rule (PvP collision, hitboxes). Not this game.
- 600ms = RuneScape's deliberate mechanical feel. ~100-150ms = modern responsive. Pick on feel, not tech.
- Discrete ticks make the server replayable: record inputs → feed a fresh server → diff state. Build the tick loop with replay in mind from tick zero.
- Positions are floats now, so replay diffs need epsilon compare, not equality.

## Persistence — dupe bugs are the thing that will hurt

Item duplication is the defining failure of this genre. A dupe found in production is unfixable after
the fact — you can patch the hole but not un-print the items.

- Every inventory change is one transaction. Trades/bank touch two inventories — same transaction or neither.
- Requests idempotent. Sequence-number every request, dedupe server-side. Reconnect must not double-apply.
- Validate against server state only. Client sends slot indices; server looks up what's actually there.
- Never delete-then-insert. Move within a transaction.
- Postgres over SQLite even for one server.

## Milestones

Ordering principle: retire the riskiest assumption first. The risk is multiplayer + persistence
colliding, not gameplay content.

### M0 — movement, no inventory

Two clients connect, click to move, see each other walk.

- WebSocket transport, Go tick loop, position broadcast, client interpolation.
- **Stub the pathfinding.** Flat plane, no obstacles, `path = [current_pos, click_pos]`.
  The polyline protocol doesn't care where the points came from — real navmesh swaps in later
  with zero protocol change.
- No DB, no items, hardcoded player IDs.

Navmesh + A* + funnel is 1-2 weeks that produces nothing playable. Don't let it block a first build.

### M1 — MVP: contested pickup

**Two clients, one item on the ground, both click it. Exactly one gets it.**

That one scenario exercises transport, tick loop, server authority, broadcast, race handling, and a
transactional inventory write at once. Survives a server restart = architecture proven.

- Postgres wired. One item type. Pickup + drop.
- Drop, not crafting — it's the reverse transaction, tests atomicity both directions, zero content work.
- Crafting shape (if wanted): one recipe, two inputs, one output. Easy CRUD, not where risk lives.
- Automate the contested-pickup test. Two scripted clients, same tick, assert one gained and one didn't.
  Not a thing to check by hand with two windows.

### M2 — reconnect

Disconnect mid-action is where dupes breed. Sequence numbers + server-side dedupe.

### Later

Real navmesh, auth/accounts, skills/XP, multiple recipes, map content, interest management.

### Cut from M0/M1

- Auth — hardcode two player IDs. Known work, zero risk, pure time.
- Art — magenta/blue capsules, one yellow box for the item.
- Skills, XP, recipes, map content. All content, no architecture.

Build the JSON event log into the Go server from tick zero. Retrofitting after inventory exists
means touching every mutation twice.
