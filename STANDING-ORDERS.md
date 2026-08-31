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
  Split into five units, one PR each, per **Unit sizing** below.
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

## Coordination, deliberately collapsed

This program is roughly four units across two tracks. That is well under the size where a
state store, a computed merge frontier, and per-track sub-coordinators pay for themselves, so
none of them exist. What survives the collapse, because it is what actually catches defects:

- The brief template. Every worker spawn fills goal, scope, context, acceptance, verify,
  timebox, forbidden, and report. A field you cannot fill is a unit you have not scoped.
- One writer per branch, isolated in its own worktree, pushing to origin before it reports.
- A verifier on a different model family from the writer, for any unit whose verification is
  expensive or judgment-laden.
- No merge without a verdict. **The PR body is the ledger.** It records the verdict, the head
  SHA it applies to, and the commands actually run. A new head SHA voids the verdict, so a
  branch that moves after verification gets re-verified before it merges.

Reintroduce the store only if the queue outgrows a single drain. It has not.

## Unit sizing

A unit is one PR, one writer, one branch, one review sitting. Cut units on these lines, in
order, and prefer more small PRs over fewer large ones.

1. **Never put two languages or two toolchains in one PR.** A reviewer switching between Go
   concurrency and Godot scene authoring inside one diff reviews neither well. `server/` and
   `client/` do not appear in the same PR.
2. **Every unit must be independently verifiable on merge day**, with a behavioral verdict, not
   `type-check-only`. A unit that can only be checked once a later unit lands is mis-cut.
3. **Cut on the risk axis before the layer axis.** Given a choice, the smaller PR is the one
   that retires the scariest assumption. A tiny diff that proves two systems can talk is worth
   more than a large one that assumes it.
4. **Split where the verification cost changes.** Headless-verifiable work and work that needs
   a display are different units, because they are different verify recipes.

A fixed written protocol is what makes small units safe. Once the coordinator has specified
the contract in the brief, separate writers cannot diverge, so "they would each guess it" stops
being a reason to merge units. Specify the contract, then cut.

## Writing a brief

Learned from what the M0a and M0c writers reported back. Each line is here because a real
worker lost real time to its absence.

1. **Point at the contract file. Do not restate it.** `PROTOCOL.md` is the wire contract.
   Enumerating its contents in a brief or a message creates a second, lossier contract, and the
   two drift. The M0a amendment message listed six items and said five bind the unit; the file
   carried a seventh binding rule the message never mentioned, and only the writer's diligence
   caught it. Say "read the file", name the commit SHA, and stop.
2. **Test files are the writer's.** A fixed file layout that lists only non-test files leaves a
   writer unsure whether adding tests is a deviation. Say so explicitly.
3. **A "known gotchas" section is where a plausible but false claim costs the most, and the
   commonest form is a correct behaviour paired with an API that does not exist.** The M0a
   brief asserted a `move_to` could carry `NaN`; JSON cannot encode `NaN` as a literal, so the
   writer built a test for a case that cannot occur. The M0b brief said to set
   `WebSocketPeer.write_mode` explicitly; the behaviour was right, binary frames really are
   rejected, but that property was removed in Godot 4.7 while its enum survived, so assigning
   it is a parse-time error and the first run never opened a socket. **Verify the API, not just
   the behaviour**, and mark a gotcha unverified rather than dressing a guess as knowledge.
   Two for two on this so far, both costing a worker its first run.
4. **Acceptance criteria must be achievable with the tooling that exists.** `-race` was required
   and is impossible here. A criterion no one can satisfy trains writers to negotiate with the
   acceptance list, which is the habit that ruins every verdict downstream.
5. **A screenshot criterion must name the specific thing that would be missing.** "Shows
   lighting" was passed by a build whose sun pointed at the sky, lit by ambient alone. "Shows a
   cast shadow" would have failed it instantly.
6. **Require the test runner to fail loudly on "tests did not run" and "tests did not finish".**
   A runner that exits 0 because the test script failed to compile reports success for a build
   that never executed. That is the worst thing a unit can hand a coordinator, and it shipped
   once already.
7. **A worker branching off an unmerged sibling branch reads stale shared docs.** Its worktree
   has the sibling's copy of `NOTES.md` and `PROTOCOL.md`, not `main`'s. Naming the files and
   saying "get them from `origin/main`" is not enough; a worker will read what is in front of
   it. **Have the worker run `git merge origin/main` into its branch before it writes anything**,
   and say so as a step rather than as a caveat.
8. **Write FORBIDDEN's merge ban as "no merge *to `main`*".** A bare "no merge" collides
   head-on with rule 7, and the M0b writer hit exactly that: `main` moved under it mid-unit,
   its acceptance list required M0d's assertions to still pass, and satisfying that required
   the merge its own FORBIDDEN section prohibited. It merged, said so, and explained the
   reasoning, which was the right call. The brief should not have made it choose. Merging
   `origin/main` **into** a branch is required; merging a branch into `main` is the
   coordinator's job alone.
9. **A brief that names sibling files must name the SHA they exist at.** The M0b brief listed
   two files it must not modify that did not exist yet at its branch point. That is confusing
   at best, and at worst it is the first hint that `main` has moved, arriving as a puzzle
   rather than as a fact.

## Verifying a verification

A sabotage test only covers the failure modes you thought to list.

The M0c test runner was verified by an independent verifier that broke it three ways, a syntax
error, a false assertion, and a hang, and confirmed a loud failure each time. The M0d verifier,
told to invent modes nobody had tried, found two more, both real and both in the newer runner:

- **A scene suite calling `get_tree().quit(0)` in `_ready` exits 0** with zero assertions run
  and no `PASS` line. Anything keying on exit code reads green.
- **An infinite loop in a tree-free suite runs during `_initialize`**, before any main-loop
  iteration, so neither the frame watchdog nor `--quit-after` ever counts a frame. Only an
  external timeout ends it.

Four rules:

- **A verify recipe must require the runner's `PASS:` line, not merely exit 0.** Exit code
  alone cannot distinguish a green run from a run that quit before asserting anything. This
  costs one `grep` and closes the worst of the two modes above at the recipe level.
- **Any bound a test runner enforces must be below the `--quit-after` it runs under**, or the
  harness exits successfully before the bound is reached and the bound is decorative.
- **Treat a passed sabotage suite as evidence about the modes tested, not about the runner.**
  When a later unit finds a new hole, add that mode to the list rather than treating the
  earlier verification as having been wrong. The verification was correct and incomplete,
  which is the normal state of every verification.
- **Reproduce a claim about another unit's code before writing it down as fact.** See below.

### A correction, and the rule that came from it

An earlier version of this section stated that M0c's merged runner printed `PASS` and exited 0
on a soft compile failure, and that its watchdog could never fire. **Both were false, and the
coordinator wrote them here from a worker's report without reproducing either.**

The M0d verifier reproduced both against M0c's actual merged code. The soft-compile failure is
not reachable in that runner at all: it has no tree-free lane, so a broken `const` makes the
whole script fail to load and the frame-10 grace check catches it, exit 1. And `--quit-after
900` did not exist in M0c; its documented command carried no such flag, and under that command
the watchdog demonstrably fired. The M0c verifier's report was accurate all along.

What was true is the engineering. The `can_instantiate()` guard M0d added is correct and
load-bearing for the tree-free architecture M0d itself introduced, and a bound above a
`--quit-after` is genuinely decorative now that the recipe documents that flag.

**The rule: a worker's claim about a sibling unit's code is a hypothesis until someone
reproduces it.** A claim about its own work is evidence, because the worker ran it. A claim
about code it did not write, especially already-merged code, is the case where a plausible
story travels furthest before anyone checks. Do not promote one into this file until it has
been reproduced against the merged artifact.

## Pasting these orders

Paste this file verbatim into every worker spawn and every resume, and **name the commit SHA
the paste came from**. This file changes as the program learns, so an unpinned paste silently
drifts from the file on disk and the worker cannot tell which one binds. On conflict, the file
in the repo wins and the worker reports the drift.

## Program state

Bookkeeping from the previous session is landed. The 3D, 150ms, and desktop-only decisions are
recorded in `NOTES.md`, along with the ground-plane `(x, z)` coordinate convention that the 3D
decision left ambiguous.

- **M0c merged**, PR #1, verdict `live-ui-verified`. Godot world, orbiting camera, ground
  raycast. 27 assertions, zero `add_child`, cast shadow confirmed by an independent verifier
  that also broke the test runner three ways.
- **M0a merged**, PR #2, verdict `unit-test-verified`. Go server, tick loop, WebSocket hub,
  event log. 59 tests, the concurrency-sensitive ones re-run 20 times with no flake, and a
  single-ownership audit done by reading because `-race` is unavailable.
- **M0d** is verified and awaiting merge on `m0d-walker`. Tick clock, polyline walker, player
  avatar. 142 assertions.
- **M0b** is in flight on `m0b-interop`. Godot to Go interop plus the client networking layer.
- **M0f** is in flight on `m0f-server-tests`. Closes the two coverage gaps M0a's verifier
  filed: the bounded tick catch-up and the slow-client drop, both enforced but untested.
- **M0e** is the join and runs last. It needs everything above.
- **M1** and **M2** are not scoped yet and must not be until M0's protocol friction is known.
  What M0b reports after real frames cross a real socket is the last input to M1's design.

**Outstanding, needs the human, not blocking anything.** No C compiler, so `-race` has never
run against the server. See *Verified tooling*.

A first attempt at M0 as a single server-plus-client unit was spawned and killed before it
committed. The cut was wrong: it put two toolchains in one PR, and the reason given for
merging them (that separate writers would guess the protocol and diverge) was already void,
because the coordinator had fixed the protocol in the brief. **Unit sizing** above is the rule
that came out of it.
