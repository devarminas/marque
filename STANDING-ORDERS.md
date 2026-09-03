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

Full detail in `NOTES.md`. Program state, verdicts, and the per-unit history live in
`COORDINATION.md`, which is coordinator-facing and never pasted. This section is only what a
worker needs to know about where the program is.

- **M0, closed.** Two clients connect, click to move, and each sees the other walk. Seven
  units, seven PRs, verified in both directions by observation rather than inference.
- **M1, closed.** One item on the ground, two clients click it, exactly one gets it. Pickup and
  drop, in-memory store behind a `Store` interface. Ten units, ten PRs. **The wire contract for
  all of it is in `PROTOCOL.md` under the M1 markers. Read it; do not re-derive it and do not
  negotiate with it.**
- **M1j, the one open unit.** PowerShell and markdown. Harden both demos and correct two
  documents. `two_client_demo.ps1` still passes a *teleporting* server, because it asserts the
  server finished a walk and never that it walked; `contested_pickup_demo.ps1` already carries
  the plausibility check to port. `contested_pickup_demo.ps1` asserts nothing about player
  position, so a loser halted at the wrong coordinates passes it.
- **M2, next.** Reconnect. Sequence numbers and server-side dedupe. `PROTOCOL.md`'s **M2**
  markers name what is reserved.

**This section used to carry a paragraph of history per unit, seventy-eight lines of it, for
units that are all now merged.** Every line here is paid for on every worker spawn, which is the
whole reason this file states that it is kept short. The history was not deleted; it is in
`COORDINATION.md` where a coordinator can read it and a worker does not have to skim past it.

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
