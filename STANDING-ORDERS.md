# Project Marque — Standing Orders

Operating contract for the coordinator session. Paste verbatim into every worker spawn and
every resume. Directives decay across resumes.

## What this is

RuneScape-like point-and-click farming/crafting MMO. Multiplayer, persistent inventory,
single authoritative server. Codename: Project Marque.

Repo: `github.com/devarminas/marque` (private). Local: `C:\Users\armin\Documents\Projects\game\marque`.

## Settled. Do not re-open these.

1. Client is Godot 4.7, GDScript, **3D with an orbiting camera** above and behind the player.
2. **Forward+ renderer, desktop only.** Browser export is not a goal.
3. Server is Go 1.27. Single authoritative server.
4. **Tick rate 150ms.** One constant, deliberately revisitable once there is gameplay to feel.
5. Transport is WebSocket carrying JSON. Monorepo with `server/` and `client/`.
6. Storage is in-memory behind a `Store` interface. Postgres arrives later with zero game-logic change.
7. Pathfinding lives only on the server. Client walks polylines it is given. M0 stubs it to a
   straight line; real navmesh comes later.
8. One goroutine owns all game state. The tick loop is the transaction boundary, not DB transactions.
9. Client sends intents, never facts. Client state is a cache with zero authority.
10. Game logic never reaches into the visual tree.

## Deciding without the human

**RuneScape is the tiebreaker.** Any gameplay question RS already answers, take RS's answer and
move on. Inventory size, XP curve shape, click-to-interact semantics, banking, drop mechanics,
skill gating. Do not ask.

For a genuine fork with no RS precedent, decide it yourself and log it. Spawning an LLM to argue
both sides is encouraged and cheaper than a human turn. Record the call and mark it revisitable.

Park anything that is real fine-tuning (numbers, pacing, feel, art direction) in a running
`FOLLOW-UPS.md` list for when the human is available. Do not block on it.

Escalate only for irreversible actions, a standing order contradicting observed reality, or a
program-level dead end that survived a replan.

## Scene authoring

Enforced in `CLAUDE.md`. Static content is authored in `.tscn`, never built by script. Level
geometry, static props, UI layout, lighting, cameras go in the scene file.

Scripts create nodes only when existence is genuine runtime behavior. Spawned remote players,
dropped items, and projectiles qualify. An `add_child()` in `_ready()` that always adds the same
node does not.

## Delivery

- One unit per PR. One writer per branch.
- Verifier runs on a different model family than the writer.
- No merge to `main` without a verdict better than `type-check-only` for behavioral work.
- `interrogate` is adversarial multi-model review of a diff. It is not a channel for asking the
  human questions.
- `create-verification-skill` runs once M0 produces a runnable client and server, not before.
  Against an empty repo it would describe an app that does not exist.

## Verified tooling

Go 1.27.0, compiles and runs and tests, module proxy reachable. Godot 4.7.2. gh 2.97.0
authenticated as `devarminas`. git 2.55.

Absent: `bun`, so the orch CLI is unavailable. Absent: Postgres, not needed until after M1.

## Milestones

Full detail in `NOTES.md`. Summary:

- **M0**, pilot. Two clients connect, click to move, see each other walk. Stubbed straight-line
  pathing, no DB, no items, hardcoded player ids. JSON event log wired from tick zero.
- **M1**, MVP. One item on the ground, two clients click it, exactly one gets it. Pickup and
  drop. In-memory store. Survives a server restart is out of scope until Postgres.
- **M2**. Reconnect. Sequence numbers and server-side dedupe.

## First act

The 3D, 150ms, and desktop-only decisions above are **not yet committed** to `NOTES.md`.
Land them there, commit this file, then run M0 as the pilot.
