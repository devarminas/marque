# Coordination playbook

How the coordinator runs this program. **Workers do not need this file and it is not pasted
into briefs.** It was carved out of `STANDING-ORDERS.md`, which had grown to 329 lines, most of
them lessons about brief-writing and verification that a worker has no use for while obeying.

`STANDING-ORDERS.md` is the worker contract and stays small enough to paste verbatim, which is
what it is for.

## Where state lives

Program state lives in Linear, project *Project Marque*:
`https://linear.app/arminas/project/project-marque-525be456de70`.

- A milestone is a Linear milestone.
- A unit is a Linear issue labelled `Unit`, under its milestone, whose description is the brief
  the coordinator pastes into the writer's prompt. A merged unit's issue records the verdict, the
  head SHA it applies to, and the PR link. The PR body carries the same ledger.
- A parked decision or tuning knob is a Linear issue labelled `Follow-up`.
- Shared verify recipes are a Linear document.

The repo docs hold only what does not change per unit: the wire contract (`PROTOCOL.md`), the
worker contract (`STANDING-ORDERS.md`), design rationale and Godot traps (`NOTES.md`), and this
playbook. Nothing in the repo records which unit is in flight.

## Coordination, deliberately collapsed

M0 was seven units across two tracks. M1 was cut as five and ran to ten unit PRs, every addition
opened because a verifier found something real rather than because the plan grew. That is still under
the size where a state store, a computed merge frontier, and per-track sub-coordinators pay for
themselves, so none of them exist. What survives the collapse, because it is what actually
catches defects:

- The brief template. Every worker spawn fills goal, scope, context, acceptance, verify,
  timebox, forbidden, and report. A field you cannot fill is a unit you have not scoped.
- One writer per branch, isolated in its own worktree, pushing to origin before it reports.
- A verifier on a different model family from the writer, for any unit whose verification is
  expensive or judgment-laden.
- No merge without a verdict. **The PR body is the ledger.** It records the verdict, the head
  SHA it applies to, and the commands actually run. A new head SHA voids the verdict, so a
  branch that moves after verification gets re-verified before it merges.

Linear stays the program store. orch via bun on poteto-mode `scripts/orch/orch.ts` is optional
bookkeeping when a single drain is not enough.

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
4. **Acceptance criteria must be achievable with the tooling that exists.** A criterion no one
   can satisfy trains writers to negotiate with the acceptance list, which is the habit that
   ruins every verdict downstream. See *Tooling* in `STANDING-ORDERS.md`.
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
10. **Open every worker brief with the absolute `SKILL.md` path, and gate on the playbook
    block.** The Skill tool and `/poteto-mode` slash refuse for workers (`disable-model-invocation`);
    only a file Read loads the skill. Every brief must include the absolute path to
    poteto-mode `SKILL.md` (coordinator resolves it once per machine or session), tell the
    worker to Read that path before any work, to copy its matched playbook's steps into its
    todolist, and to end its report with the playbook block. The gate must ask for that block,
    every step done or `skip: <reason>`, because a brief's own report format otherwise displaces
    the checklist entirely. **A playbook block where Opening a PR, deslop, or no-comments is
    skipped with a weak reason (`N/A`, `timebox`, `already clean`, or similar) is a fail. Send
    the writer back.**

## Active verification rules

- A verify recipe requires exit 0 **and** the runner marker on the **last** line of redirected output. Grep is not enough.
- Redirect harnesses to a file. Do not pipe them.
- A worker's claim about anything it did not just run is a hypothesis until reproduced.
- Never run timing-sensitive Godot work concurrently with other Godot agents.
- Split a verification when checks exceed roughly four, or span re-running, reading, and adversarial probing. Give each half its own verdict.
- A new head SHA voids a verdict unless the delta is shown disjoint from what the verdict covered.
- Contested-demo `:541` / `:718` tick skew and sky-band still-camera flake: see Recipe W and
  `.claude/skills/verify-marque/SKILL.md` Known flake.

## Picking this up in a new session

1. Open Linear *Project Marque*. Find Todo Unit issues. Their descriptions are the briefs.
   Issues labelled `Follow-up` are parked and block nothing.
2. Read `STANDING-ORDERS.md`, then this file, then `PROTOCOL.md` and `NOTES.md`.
3. Prove the stack is alive before dispatching anything. Recipes G/H/W below; redirect output to a
   file, do not pipe.
4. Run the dispatch loop below on the first Todo issue.

## The dispatch loop

**The coordinator is a dispatcher, not an implementer.** It does not write code, deep-review
diffs, or reason about the domain. Completions that need a diff judgment become verifier units;
the coordinator gates on verdicts, not on reading the patch. A coordinator that finds itself
designing something has taken a worker's job.

**Default: one unit at a time** for a single-drain coordinator. An **Orchestrate** program may
run a rolling window of independent units (still one writer per branch; shared files and Godot
serialize) per that playbook. Do not invent parallel writers outside Orchestrate. Every agent is
`poteto-agent` and every brief opens with the `SKILL.md` read instruction from rule 10 under
*Writing a brief*.

1. **Write.** One unit, one branch, one worktree (sibling of the repo or as the brief names).
   `git worktree add`. Use a Task-allowed model on this Cursor host (often `inherit` /
   `composer-2.5-fast`, or the pstack-models rule). Do not invent slugs Task rejects. Paste
   `STANDING-ORDERS.md` verbatim and name the SHA you took it from. Paste the unit's brief from
   its Linear issue (absolute poteto `SKILL.md` path included per rule 10).
2. **Gate.** The writer must report a pushed branch, a head SHA, and the commands it ran with
   their exit codes and final lines. Missing any of those, send it back. The report must also
   carry the playbook block, the matched playbook and every step marked done or
   `skip: <reason>`. A missing block, one where every step is a skip, or a soft-skip fail under
   rule 10, sends the writer back. **Also require proof of no-comments:** Comment Sicko agent id
   or report path, plus a short summary of deletions (same receipt as STANDING-ORDERS Delivery).
   No merge without that proof. Deslop: soft-skip ban only; no separate receipt.
3. **Verify.** Different model family from the writer when Task allows a second family; never
   the writer itself. Over about four checks, or if the checks span re-running and reading and
   adversarial probing, split into two agents with a verdict each. *Active verification rules*
   above.
4. **Gate.** The coordinator merges only after a verdict better than `type-check-only` from an
   agent that did not write the code. CI green is not a verdict. A writer proving its own fix is
   not a verdict. A verifier may note leftover narrating comments as findings; those void land
   the same way a failed acceptance does.
5. **Findings.** Send them to the writer as a numbered list demanding a per-item answer,
   including the items it declines. A new head SHA voids the verdict. Either re-verify, or show
   the delta is disjoint from what the verdict covered. Showing means running the diff, not
   asserting.
6. **PR body is the ledger.** Before merge it records every verdict, the SHA each applies to,
   and the commands actually run. Append it yourself if the writer did not.
7. **Merge.** `gh pr merge <n> --merge`. If the permission classifier blocks you, hand the human
   the command and move on. Do not work around it.
8. **Update Linear.** On the unit's issue record the verdict, the head SHA it applies to, and
   the PR link, then move the issue to Done. If the merge closes a milestone, update the
   milestone description. If the merge makes a repo doc false, fix that doc in one commit on
   `main`. Then take the next Todo issue.

**Two rules that are not optional.** Only one agent may drive Godot at a time; the windowed
demos read every displacement as zero under load. And a worker's claim about anything it did not
just run is a hypothesis, including claims about the coordinator's own briefs.

## Recipes and brief paste rules

Open milestones and units live in Linear.

**Every brief, in addition to its issue text.** Paste `STANDING-ORDERS.md` verbatim and name its
SHA. Include the absolute path to poteto-mode `SKILL.md` (rule 10). Branch from current
`origin/main`, and run `git merge origin/main` into the branch before writing anything. Test
files are the writer's. Read `PROTOCOL.md` at the branch's SHA rather than any summary. Where a
brief states a rule, the rule is the coordinator's decision and the writer copies it into
`PROTOCOL.md` first, then codes against the file. A verify recipe passes only on exit 0 **and**
the marker read from the last line of the redirected output. Redirect, never pipe. Only one
Godot-driving agent at a time when a windowed demo is in the recipe.

### The three recipes, named once

Briefs name these by letter. Prefer the Linear document that carries the same text when it
exists; keep the commands here for coordinators without Linear access.

**Recipe G.** From `server/`, with a C toolchain Go can use as `CC` on PATH. Prefer PowerShell
(matches H/W). Git Bash form is equivalent.

PowerShell:

    $env:CGO_ENABLED = "1"
    go test -race ./... > ../out-race.txt 2>&1; echo $LASTEXITCODE; Get-Content ../out-race.txt -Tail 5

Git Bash:

    CGO_ENABLED=1 go test -race ./... > ../out-race.txt 2>&1; echo EXIT=$?; tail -5 ../out-race.txt

Pass: exit 0 (or `EXIT=0`), an `ok` line for each of `internal/game`, `internal/gamelog`,
`internal/net`, no `DATA RACE`, no `FAIL` anywhere in `out-race.txt`. `internal/net` is slow
under instrumentation.

**Recipe H.** From the repo root, PowerShell:

    powershell -ExecutionPolicy Bypass -File scripts/interop_test.ps1 > out-interop.txt 2>&1; echo $LASTEXITCODE
    Get-Content out-interop.txt -Tail 3

Pass: exit 0, last line `INTEROP OK`, and inside the transcript `INTEROP RAN: N assertions, 0
failed`, `WIRING RAN: N assertions, 0 failed`, and `PASS: N assertion(s) held across M suite(s)`
with M equal to the suite count in `client/tests/run_tests.gd`. Report the numbers you got. The
transcript also prints the server's whole event log under `--- marqued event log ---`; several
acceptance criteria are read from it.

**Recipe W.** From the repo root, PowerShell, idle machine, one demo at a time:

    powershell -ExecutionPolicy Bypass -File scripts/two_client_demo.ps1 > out-two.txt 2>&1; echo $LASTEXITCODE; Get-Content out-two.txt -Tail 3
    powershell -ExecutionPolicy Bypass -File scripts/contested_pickup_demo.ps1 > out-contested.txt 2>&1; echo $LASTEXITCODE; Get-Content out-contested.txt -Tail 3

Pass: exit 0 and last lines `TWO CLIENT DEMO OK` and `CONTESTED PICKUP DEMO OK`. A contested run
that fails only on `:541` or `:718` is tick-skew baseline, not a regression; rerun up to three
times. If `two_client_demo.ps1` fails only on the sky-band still-camera control, treat it as the
Known flake in `.claude/skills/verify-marque/SKILL.md`, not a finding, unless idle-machine
control or geometry also fails. Any other failing line is a finding.

[ARM-107](https://linear.app/arminas/issue/ARM-107/fix-wrong-one-way-latency-comment-in-tick-clockgd).
