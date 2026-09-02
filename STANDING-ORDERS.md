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

**`go test -race` runs. Every Go unit's verify recipe uses it.** It is not on PATH by default,
so put it there:

    export PATH="/c/Users/armin/AppData/Local/Microsoft/WinGet/Packages/MartinStorsjo.LLVM-MinGW.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe/llvm-mingw-20260616-ucrt-x86_64/bin:$PATH"

That is LLVM-MinGW UCRT `22.1.8-20260616`, `clang` targeting `x86_64-w64-windows-gnu`, exposed
as `gcc.exe` and `cc.exe`. Go picks it up as `CC=gcc` with `CGO_ENABLED=1`. Run
`CGO_ENABLED=1 go test -race ./...` from `server/`.

**The baseline is clean, measured rather than assumed.** On `main` at `06e542e`, all three
packages pass, zero data races, exit 0, with `internal/net` alone taking 86 seconds under
instrumentation. A race the detector reports on your branch is yours. One reported in code you
did not touch is a finding against `main` and a new unit; report it and do not fix it.

**Say what ran and what it found, not that the server is race-free.** A clean `-race` run means
no race was *detected* along the paths the tests exercise. It is not a proof of absence.

This paragraph used to say a C compiler was absent, that `-race` could never run, and that a Go
unit's ledger row should record dropping it. That was true from M0 until the human installed the
toolchain mid-session on 2026-09-02, and it was **pasted verbatim into every worker spawn while
it was true**. It is corrected here rather than deleted, because a worker who read the old
version will otherwise believe it and negotiate its acceptance list downward.

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
  - **M1b**, Go. `drop`, pickup's reverse transaction. Needs M1a.

    This line used to say "and the full-inventory refusal", which was wrong when written.
    **A drop empties a slot and can never find the inventory full.** That refusal belongs to
    pickup on arrival, `PROTOCOL.md` has always said so, and M1a shipped it. Its writer caught
    the contradiction and reported it rather than inventing a case to satisfy the summary.
  - **M1d**, Godot. Clicking an item sends `pickup`, and an inventory panel fed by `inventory`.
    Needs M1a and M1c.
  - **M1e**, the milestone. Two real clients race for one item; exactly one gets it, by
    observation. A `scripts/` demo alongside `two_client_demo.ps1`. Needs everything above.

  Four more units, none in the original cut, each opened because something real was found:

  - **M1f**, Go. Implement the slow-client condemnation decision `PROTOCOL.md` now records:
    classify by cause, latch on first condemnation. Found because a worker wrote `slow_client`
    and `peer_gone` into a document as if they were current behaviour when nothing implements
    them. Independent of everything else.
  - **M1g**, PowerShell and markdown. Make `two_client_demo.ps1` assert server state, stop it
    deleting the event log, stop both harnesses running into a dirty output directory, and land
    the verification skill that PR #9 failed on. **Blocks M1e**, which otherwise inherits a demo
    that cannot tell a frozen server from a live one.
  - **M1h**, Godot. Merged, PR #11, `unit-test-verified`. Two over-tight assertions in
    `client/tests/test_interop.gd` asserted on a session-wide accumulator of unknown top-level
    keys, plus the receiver's half of the null-list rule.

    **The sentence that used to be here said "any M1 message trips them and `inventory` does".
    That was false, and it was already false when it was committed.** `inventory` became a
    *known* message when M1c merged at 11:16:11, so it never reaches the unknown path at all;
    this line landed at 11:16:56, forty-five seconds later. The write and the merge raced and
    the write lost. M1a saw those assertions fail only because its branch predated the merge.
    The assertions were still worth fixing, because any genuinely unknown key breaks them, but
    M1a's real exposure was the null rule alone. Recorded because a coordinator writing program
    state from a worker's report, forty-five seconds after the thing that falsified it, is a
    failure mode worth naming.
  - **M1k**, Godot. Make the inventory panel opaque and move whatever depends on it being
    click-through. Three behaviours today, one intended: chrome walks you, empty slots eat the
    click, occupied slots drop. Proven live, not inferred. `test_wiring`'s live half clicks
    through the panel on purpose, so `CLICK_AT` or the panel has to move with it.
  - **M1i**, Go, small and unscheduled. `hub_test.go:752` calls a `*testing.T`-touching helper
    from a background goroutine, which the harness's own comment forbids. Pre-existing,
    test-only, found while reading. Not blocking anything.
- **M2**. Reconnect. Sequence numbers and server-side dedupe.

## Pasting these orders

Paste this file verbatim into every worker spawn and every resume, and **name the commit SHA
the paste came from**. This file changes as the program learns, so an unpinned paste silently
drifts from the file on disk and the worker cannot tell which one binds.

**On conflict, the newer of the two wins, and you say which one you used.** Compare the paste's
named SHA against your worktree's copy. If your branch forked before the paste's commit, the
**paste** is newer and it binds. If `main` has moved past the paste, run `git fetch` and read
`origin/main`'s copy, which is newer than both.

This used to say "the file in the repo wins", flatly, and an M1b verifier caught that it is
wrong in the commonest case. Its branch forked one commit before a line here was corrected, so
its worktree carried the falsehood and the paste carried the fix. **Obeying the old rule
literally would have resurrected a corrected falsehood**, which is the precise opposite of what
the rule is for. Neither copy is authoritative by virtue of being on disk; recency is what
decides, and `origin/main` settles it.

## Picking this up in a new session

Everything a coordinator needs is in this repo. Nothing lives only in a chat transcript.

**Read this file, then [COORDINATION.md](COORDINATION.md), then `PROTOCOL.md`, `NOTES.md`, and
`FOLLOW-UPS.md`.** `COORDINATION.md` carries the program state: which units are merged, what
verdict each PR body records, what the two liveness commands actually prove, and every lesson
about writing briefs and sizing verifications. Each merged PR body is that unit's ledger row.

**This file is the worker contract and nothing else.** It used to also carry the program's
running state, and it grew by half in one session until it was mostly history a worker must skim
past to reach the rules it has to obey. The paragraph above about pasting it verbatim is why
that matters: every line here is paid for on every spawn. Program state moved to
`COORDINATION.md`, which is coordinator-facing and never pasted.

**Two protocol decisions were due before M1's first message and both are settled**, with their
reasoning, in `PROTOCOL.md`. The cause is authoritative when a slow client dies, never the
detector, and the first condemnation latches. Every entity family gets its own message names and
its own id space.

**Do not re-derive settled decisions from scratch.** They are written down, with the reasoning
and the evidence, in the files above.
