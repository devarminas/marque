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

Items 7 to 10 restate the architecture invariants `CLAUDE.md` owns. They stay here only because
this file is pasted verbatim into worker prompts.

## Deciding without the human

**RuneScape is the tiebreaker.** Any gameplay question RS already answers, take RS's answer and
move on. Inventory size, XP curve shape, click-to-interact semantics, banking, drop mechanics,
skill gating. Do not ask.

For a genuine fork with no RS precedent, decide it yourself and log it. Spawning an LLM to argue
both sides is encouraged and cheaper than a human turn. Record the call and mark it revisitable.

Park anything that is real fine-tuning (numbers, pacing, feel, art direction) as a Linear issue
labelled `Follow-up` in project *Project Marque*, for when the human is available. A worker that
cannot reach Linear names the item in its report and the coordinator files it. Do not block on
it.

Escalate only for irreversible actions, a standing order contradicting observed reality, or a
program-level dead end that survived a replan.

## Scene authoring

`CLAUDE.md` owns this rule. It is repeated here only because this file is pasted verbatim into
worker prompts. Static content is authored in `.tscn`, never built by script. Level geometry,
static props, UI layout, lighting, cameras go in the scene file.

Scripts create nodes only when existence is genuine runtime behavior. Spawned remote players,
dropped items, and projectiles qualify. An `add_child()` in `_ready()` that always adds the same
node does not.

## Delivery

- One unit per PR. One writer per branch.
- Read `C:/Users/armin/.claude/skills/poteto-mode/SKILL.md` as a file before any work. The Skill
  tool and `/poteto-mode` slash refuse for workers; only a file Read loads it.
- Match Feature (or Bug fix). Copy that playbook's steps into the todolist. End the report with
  the playbook block: every step done or `skip: <reason>`.
- Before PR: run Opening a PR. That includes deslop (cursor-team-kit) then no-comments / Comment
  Sicko on the unit diff. Soft skips on Opening a PR, deslop, or no-comments are forbidden.
  Narrating `//` and `##` that restate the next lines are land blockers.
- `interrogate` is adversarial multi-model review of a diff. It is not a channel for asking the
  human. Run it when Opening a PR or Feature requires it, or when the brief says so.
- Verifier runs on a different model family than the writer.
- No merge to `main` without a verdict better than `type-check-only` for behavioral work.
- `.claude/skills/verify-marque/SKILL.md` is the project's verification skill. Any behavioural
  claim about the client or the server is proven the way it describes, before any generic driver.

## Verified tooling

Go 1.27.0, compiles and runs and tests, module proxy reachable. Godot 4.7.2. gh 2.97.0
authenticated as `devarminas`. git 2.55. bun 1.4.1.

The orch CLI is `bun` on
`C:/Users/armin/.claude/skills/poteto-mode/scripts/orch/orch.ts`. Linear stays the program store;
orch is optional bookkeeping when a single drain is enough. Absent: Postgres, not needed until
after M1.

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

Which milestone is open, which units are Todo, and which Follow-ups are parked live only in
Linear, project *Project Marque*. The coordinator pastes each unit's brief into the worker's
prompt. Do not record program progress in this file.

The wire contract for everything shipped is `PROTOCOL.md`, under its milestone markers. Read it.
Do not re-derive it and do not negotiate with it. A unit that changes it copies the coordinator's
rule into the file first, then codes against the file. The M1j finding that two clients agree on
a tick number rather than a moment is recorded in `COORDINATION.md`, *Lessons from M1*.

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

1. Open the Linear project, `https://linear.app/arminas/project/project-marque-525be456de70`.
   Find Todo Unit issues. Their descriptions are the briefs. Issues labelled `Follow-up` are
   parked and block nothing.
2. Read this file, then [COORDINATION.md](COORDINATION.md) for the dispatch loop and every
   lesson about writing briefs and sizing verifications, then `PROTOCOL.md` and `NOTES.md`.
3. Prove the stack is alive before dispatching anything. Recipe H and Recipe W in
   `COORDINATION.md` are the commands. Redirect them to a file; do not pipe them.
4. Run the dispatch loop from `COORDINATION.md` on the first Todo issue.

This file is the worker contract and nothing else. Nothing about which unit is in flight lives
here or in any other repo doc; Linear holds it. Settled decisions are written down with their
reasoning in `PROTOCOL.md` and `NOTES.md`. Do not re-derive them.
