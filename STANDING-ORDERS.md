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
  drop. In-memory store behind a `Store` interface. Postgres and surviving a restart are out of
  scope. **The wire contract for all of it is already written**: `PROTOCOL.md`, the sections
  marked **M1**. Read them; do not re-derive them and do not negotiate with them.
  - **M1a**, Go. The `Store` interface, ground items, inventory, the `pickup` intent, and
    contested resolution. Ends in a Go test where two real WebSocket clients race for one item
    and exactly one wins. Depends on nothing.
  - **M1c**, Godot. The second registry: a ground-item body and an item container driven by
    `welcome.items`, `item_spawn`, and `item_despawn`. Verified against scripted frames, no
    server. Depends on nothing, so it runs alongside M1a.
  - **M1b**, Go. `drop`, the reverse transaction, and the full-inventory refusal. Needs M1a.
  - **M1d**, Godot. Clicking an item sends `pickup`, and an inventory panel fed by `inventory`.
    Needs M1a and M1c.
  - **M1e**, the milestone. Two real clients race for one item; exactly one gets it, by
    observation. A `scripts/` demo alongside `two_client_demo.ps1`. Needs everything above.
- **M2**. Reconnect. Sequence numbers and server-side dedupe.

## Pasting these orders

Paste this file verbatim into every worker spawn and every resume, and **name the commit SHA
the paste came from**. This file changes as the program learns, so an unpinned paste silently
drifts from the file on disk and the worker cannot tell which one binds. On conflict, the file
in the repo wins and the worker reports the drift.

## Program state

**M0 is complete.** Seven units, seven PRs, each with a verdict recorded in its PR body, which
is the ledger.

| Unit | PR | Verdict | What |
|---|---|---|---|
| M0c | #1 | `live-ui-verified` | Godot world, orbiting camera, ground raycast |
| M0a | #2 | `unit-test-verified` | Go server, tick loop, WebSocket hub, event log |
| M0d | #3 | `live-ui-verified` | Tick clock, polyline walker, player avatar |
| M0f | #4 | `unit-test-verified` | The two untested tick-loop protections |
| M0b | #5 | `unit-test-verified` | Godot to Go interop, client networking layer |
| M0g | #6 | `unit-test-verified` | The event log records what a joining client was told |
| M0e | #7 | `live-ui-verified` | Wiring. The milestone, both directions, by observation |

**The milestone sentence holds by observation, not inference.** Two Godot clients connect to the
Go server, click the ground to move, and each sees the other walk. Each client is measured
watching the other move while its own camera is provably still, the two walks are 8.435 units
apart so neither can be mistaken for the other, and the demo fails loudly if either direction is
stationary.

Two commands tell you the stack is alive:

- `powershell -ExecutionPolicy Bypass -File scripts/interop_test.ps1` builds the server, binds a
  free port, runs the whole Godot suite against a live `marqued`, and shuts it down. 321
  assertions across 6 suites.
- `powershell -ExecutionPolicy Bypass -File scripts/two_client_demo.ps1` runs two real windowed
  clients and proves the milestone.

**Known flake, recorded so nobody debugs it twice.** The demo's still-camera control asserts
byte-exactness over the top quarter of a GPU-rendered frame. One flip was observed on a fully
static frame across eighteen measured windows, explicable only by render nondeterminism. It
fails in the safe direction, never a false pass. If the demo fails on only "the background is
not a control" with a still fraction near zero, rerun before investigating.

**Outstanding, needs the human, not blocking anything.** No C compiler, so `-race` has never run
against the server. See *Verified tooling*. `FOLLOW-UPS.md` holds everything parked for you,
including four things a first playtest will ask about.

## Picking this up in a new session

Everything a coordinator needs is in this repo. Nothing lives only in a chat transcript. Read
this file, then `COORDINATION.md`, `PROTOCOL.md`, `NOTES.md`, and `FOLLOW-UPS.md`. Each merged
PR body is that unit's ledger row: verdict, head SHA, and the commands actually run.

**M0 is closed and `main` is green. M1 is scoped and open.**

The two protocol decisions that were due before M1's first message are **both settled and
written into `PROTOCOL.md`**, with their reasoning:

- *Which reason is authoritative* when a slow client dies. The cause is authoritative, never the
  detector, and the first condemnation latches so a consequence cannot overwrite a cause.
- *Entity naming*. Every entity family gets its own message names and its own id space. The
  compatibility rules chose it: a `kind` field on `spawn` would make an M0 client render an
  acorn as a walking blue capsule, where a new top-level key makes it render nothing.

M1's whole wire contract is now in `PROTOCOL.md` under the **M1** markers, and its five units
are listed under *Milestones*. Read the contract rather than re-deriving it.

Still worth reading before touching M1: M0e's PR body, whose sharpest handover is that **the
client believes the world is made of players and only players** — no second registry, no second
container, no applier that is not about a body that walks. That is exactly what M1c builds. And
`COORDINATION.md`, which records how briefs and verifications go wrong here, including three
occasions when a claim about a dependency was written into a contract file as fact and had to be
corrected.

**Do not re-derive M0's decisions from scratch.** They are written down, with the reasoning and
the evidence, in the files above.
