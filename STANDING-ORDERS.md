# Project Marque — Standing Orders

The worker contract. Paste verbatim into every worker spawn and every resume, naming the commit
SHA it came from. Directives decay across resumes.

Kept deliberately short so that pasting it stays cheap. How the coordinator cuts units, writes
briefs, and sizes verifications lives in [COORDINATION.md](COORDINATION.md), which workers do
not need and which is never pasted into a brief.

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

**Absent: any C compiler, so `go test -race` cannot run.** Go's race detector needs cgo, cgo
needs a C toolchain, and `gcc`, `clang`, `cc`, `x86_64-w64-mingw32-gcc`, `zig`, and `tcc` are
all missing from PATH and from the usual MSYS2, MinGW, TDM, LLVM, and Strawberry install
locations. This is a **program-level gap, not a per-unit defect**. It affects every Go unit,
and it specifically means the single-goroutine-ownership invariant is verified by construction
and by concurrency tests rather than by the tool that actually proves it. Do not fail a Go unit
for it and do not make a worker try to install one.

Fix once, centrally, with `winget install --id MartinStorsjo.LLVM-MinGW.UCRT` or MSYS2
mingw-w64, then re-verify every merged Go unit under `-race` in a single pass. Until then, a Go
unit's verify recipe drops `-race` and its ledger row says so explicitly rather than silently
omitting it.

## Milestones

Full detail in `NOTES.md`. Summary:

- **M0**, pilot. Two clients connect, click to move, see each other walk. Stubbed straight-line
  pathing, no DB, no items, hardcoded player ids. JSON event log wired from tick zero.
  Split into five units, one PR each, per **Unit sizing** in `COORDINATION.md`.
  - **M0a**, Go server, complete and self-verifying. Protocol, tick loop, stubbed pathing,
    event log, WebSocket hub, two-real-client integration test. Depends on nothing.
  - **M0c**, Godot world and camera. Scene with ground, lighting, camera rig, and the empty
    container avatars will hang off. Orbit controller and click-to-ground raycast. Zero
    networking. Depends on nothing, so it runs alongside M0a.
  - **M0b**, Godot to Go interop. The smallest possible script that connects to the real
    server, sends a scripted `move_to`, and asserts on `welcome` and `path`. Headless, no
    rendering. Exists to retire the highest-risk assumption in the program in the smallest
    diff that can. Needs M0a and M0c.
  - **M0d**, the polyline walker. A node that interpolates a position from `points`,
    `start_tick`, and `speed`. Pure client logic, unit-tested headless against a fake path
    with no server involved. Needs M0c.
  - **M0e**, wiring. Network state drives avatar spawn and despawn, avatars walk their paths,
    a ground click sends a `move_to`. This is where "two clients see each other walk" is
    proven. Needs everything above.

  M0a and M0c have no dependency on each other and run concurrently. M0b and M0d likewise.
  Only M0e is a genuine join.
- **M1**, MVP. One item on the ground, two clients click it, exactly one gets it. Pickup and
  drop. In-memory store. Survives a server restart is out of scope until Postgres.
- **M2**. Reconnect. Sequence numbers and server-side dedupe.

## Pasting these orders

Paste this file verbatim into every worker spawn and every resume, and **name the commit SHA
the paste came from**. This file changes as the program learns, so an unpinned paste silently
drifts from the file on disk and the worker cannot tell which one binds. On conflict, the file
in the repo wins and the worker reports the drift.

## Program state

Bookkeeping from the previous session is landed. The 3D, 150ms, and desktop-only decisions are
recorded in `NOTES.md`, along with the ground-plane `(x, z)` coordinate convention that the 3D
decision left ambiguous.

Six units merged, each with a verdict recorded in its PR body, which is the ledger.

| Unit | PR | Verdict | What |
|---|---|---|---|
| M0c | #1 | `live-ui-verified` | Godot world, orbiting camera, ground raycast |
| M0a | #2 | `unit-test-verified` | Go server, tick loop, WebSocket hub, event log |
| M0d | #3 | `live-ui-verified` | Tick clock, polyline walker, player avatar |
| M0f | #4 | `unit-test-verified` | The two untested tick-loop protections |
| M0b | #5 | `unit-test-verified` | Godot to Go interop, client networking layer |
| M0g | #6 | `unit-test-verified` | The event log records what a joining client was told |

**Godot and Go demonstrably interoperate.** `scripts/interop_test.ps1` builds the server, binds
a free port, runs the whole Godot suite against a live `marqued`, and shuts it down. That is
the command to run to know the stack is alive.

- **M0e** is the last unit. Wiring: network state drives avatar spawn and despawn, avatars walk
  their paths, a ground click sends a `move_to`. This is where "two clients see each other
  walk" gets proven and M0 is done.
- **M1** and **M2** are not scoped yet and must not be until M0e lands.

**Outstanding, needs the human, not blocking anything.** No C compiler, so `-race` has never
run against the server. See *Verified tooling*.
