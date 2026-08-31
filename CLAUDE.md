# Project Marque

RuneScape-like point-and-click farming/crafting MMO. Codename: Project Marque.

Client: Godot 4.7 / GDScript. Server: Go. Single authoritative server.
Design decisions and milestones live in [NOTES.md](NOTES.md). Read it before starting a unit.

## Scene authoring

**Static content is authored in `.tscn` scenes, never built by script.**

- Level geometry, static props, UI layout, fixed collision bodies: place them in the scene file.
- Scripts create nodes only when the node's existence is genuine runtime behavior: spawned
  players, dropped items, projectiles, anything whose count or position is not known until runtime.
- `add_child()` in a `_ready()` that always adds the same node is a scene edit written in the
  wrong language. Put it in the scene.

Reason: scene-authored content is diffable, editable in the editor, and inspectable without
running the game. Script-built trees are none of those.

## Architecture invariants

- Client sends intents, never facts. `{"use":{"slot":3,"on":7}}`, never an inventory payload.
- The client's game state is a cache of what the server last sent. It has zero authority.
- Pathfinding lives only on the server. The client walks polylines it is given.
- One goroutine owns all game state. The tick loop is the transaction boundary.
- Game logic never reaches into the visual tree. Talk to visuals through the visual contract.
