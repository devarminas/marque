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

## Pasting these orders

Paste this file verbatim into every worker spawn and every resume, and **name the commit SHA
the paste came from**. This file changes as the program learns, so an unpinned paste silently
drifts from the file on disk and the worker cannot tell which one binds. On conflict, the file
in the repo wins and the worker reports the drift.

## Program state

Bookkeeping from the previous session is landed. The 3D, 150ms, and desktop-only decisions are
recorded in `NOTES.md`, along with the ground-plane `(x, z)` coordinate convention that the 3D
decision left ambiguous.

- **M0a** and **M0c** are in flight concurrently, on `m0a-server` and `m0c-scene`. They touch
  disjoint paths and cannot conflict. Between them they are the pilot: they falsify the brief
  template, the verify recipe, and the unit size across both toolchains at once.
- **M0b** and **M0d** are scoped and unspawned. Both need M0c's project skeleton, and M0b also
  needs M0a's server, because it verifies against a real server rather than a stub.
- **M0e** is the join and runs last.
- **M1** and **M2** are not scoped yet and must not be until M0's protocol friction is known.
  What M0a and M0b report about the wire format is the input to M1's design.

A first attempt at M0 as a single server-plus-client unit was spawned and killed before it
committed. The cut was wrong: it put two toolchains in one PR, and the reason given for
merging them (that separate writers would guess the protocol and diverge) was already void,
because the coordinator had fixed the protocol in the brief. **Unit sizing** above is the rule
that came out of it.
