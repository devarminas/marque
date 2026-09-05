# Project Marque — Standing Orders

The worker contract. Paste verbatim into every worker spawn and every resume, naming the commit
SHA it came from. Directives decay across resumes.

Kept deliberately short so that pasting it stays cheap. How the coordinator cuts units, writes
briefs, and sizes verifications lives in [COORDINATION.md](COORDINATION.md), which workers do
not need and which is never pasted into a brief.

## What this is

RuneScape-like point-and-click farming/crafting MMO. Multiplayer, persistent inventory,
single authoritative server. Codename: Project Marque.

Code and PRs: `github.com/devarminas/marque` (private). Clone or open the worktree the brief
names; do not invent a local path from this file.

## Sources of truth

- **Program state** (milestones, unit briefs, Follow-ups): Linear project *Project Marque*
  (`https://linear.app/arminas/project/project-marque-525be456de70`).
- **Code and PRs:** GitHub repo above. The PR body is the ledger for a unit's verdict and SHA.
- **Wire contract:** `PROTOCOL.md` in the repo, under its milestone markers. Read it. Do not
  re-derive it and do not negotiate with it. A unit that changes it copies the coordinator's
  rule into the file first, then codes against the file.
- **Design rationale and Godot traps:** `NOTES.md`. Do not re-derive settled decisions.

Do not record which milestone or unit is open in this file. The coordinator pastes each unit's
brief from Linear into the worker's prompt.

## Settled. Do not re-open these.

1. Client is Godot 4.7, GDScript, **3D with an orbiting camera** above and behind the player.
2. **Forward+ renderer, desktop only.** Browser export is not a goal.
3. Server is Go 1.27. Single authoritative server.
4. **Tick rate 150ms.** One constant, deliberately revisitable once there is gameplay to feel.
5. Transport is WebSocket carrying JSON. Monorepo with `server/` and `client/`.
6. Storage is in-memory behind a `Store` interface. Postgres arrives later with zero game-logic change.
7. Pathfinding lives only on the server. Client walks polylines it is given. Early milestones
   stub it to a straight line; real navmesh comes later.
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
- The brief names the absolute path to poteto-mode `SKILL.md`. Read that path as a file before
  any work. The Skill tool and `/poteto-mode` slash refuse for workers; only a file Read loads it.
- Match Feature (or Bug fix). Copy that playbook's steps into the todolist. End the report with
  the playbook block: every step done or `skip: <reason>`.
- Before PR: run Opening a PR. That includes deslop (cursor-team-kit) then no-comments / Comment
  Sicko on the unit diff. Soft skips on Opening a PR, deslop, or no-comments are forbidden.
  Narrating `//` and `##` that restate the next lines are land blockers.
- The writer report must include Comment Sicko agent id or report path, plus a short summary of
  deletions.
- `interrogate` is adversarial multi-model review of a diff. It is not a channel for asking the
  human. Run it when Opening a PR or Feature requires it, or when the brief says so.
- Verifier runs on a different model family than the writer.
- Workers never merge to `main`. They may merge `origin/main` into their branch. The coordinator
  merges only after an independent verdict better than `type-check-only` for behavioral work.
- Repo-relative `.claude/skills/verify-marque/SKILL.md` is the project's verification skill. Any
  behavioural claim about the client or the server is proven the way it describes, before any
  generic driver.

## Tooling

- Language majors are under *Settled* (Godot 4.7, Go 1.27). Confirm patch versions and CLIs on
  the machine before claiming a tool is absent. Do not negotiate the acceptance list downward.
- Every Go unit whose brief names Recipe G runs `CGO_ENABLED=1 go test -race ./...` from
  `server/`. Put a C toolchain Go can use as `CC` on PATH first. A race on your branch is yours.
  A race in code you did not touch is a finding against `main` and a new unit.
- Say what ran and what it found. A clean `-race` run means no race was *detected* on the paths
  the tests exercise. It is not a proof of absence.
- orch via bun on poteto-mode `scripts/orch/orch.ts` is optional bookkeeping when a single drain
  is enough. Linear remains the program store either way.

## Pasting these orders

Paste this file verbatim into every worker spawn and every resume, and **name the commit SHA
the paste came from**. This file changes as the program learns, so an unpinned paste silently
drifts from the file on disk and the worker cannot tell which one binds.

**On conflict, the newer of the two wins, and you say which one you used.** Compare the paste's
named SHA against your worktree's copy. If your branch forked before the paste's commit, the
**paste** is newer and it binds. If `main` has moved past the paste, run `git fetch` and read
`origin/main`'s copy, which is newer than both. Recency decides; neither copy is authoritative
only because it sits on disk.

This file is the worker contract and nothing else. Program progress lives in Linear. Code lives
on GitHub. Settled decisions live in `PROTOCOL.md` and `NOTES.md`. Coordinator pickup, dispatch,
and recipes live in [COORDINATION.md](COORDINATION.md).
