# Project Marque

## Git branches

| Kind | Pattern | Rule |
|---|---|---|
| Stable | `main` | Accepts merges from Release and Hotfix branches only. |
| Features / bug fixes | `feat/*` / `bug/*` | Always branch off `HEAD` of `main`. |

Create work as `feat/ARM-<n>` or `bug/ARM-<n>` from an up-to-date `main`, where `ARM-<n>` is the Linear issue id.

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

## Testing

```bash
godot --headless --path client --script res://tests/run_tests.gd
```

- No rendering server. Logic, physics, signals, resources all run.
- `print()` → stdout. `quit(1)` → exit code. `--quit-after N` bounds runaway loops.
- Anything visual (shaders, viewport textures) does not work headless.
- Visual checks: the game screenshots itself; do not automate the desktop.
- Behavioural client/server claims: `.claude/skills/verify-marque/SKILL.md`.
- Server: from `server/`, with a C toolchain on PATH, `CGO_ENABLED=1 go test -race ./...`.
