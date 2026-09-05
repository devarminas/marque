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
playbook of lessons about cutting and verifying units. Nothing in the repo records which unit is
in flight.

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

- **A verify recipe must require exit 0 *and* the runner's `PASS:` line. Either alone is a
  false pass, in opposite directions.** Exit code alone cannot distinguish a green run from a
  run that quit before asserting anything. And the `PASS:` line alone is worse than it looks:
  **it is unauthenticated output that any suite can print.**

  M1c's verifier demonstrated this. It made a failing suite print
  `PASS: 999 assertion(s) held across 8 suite(s)` from inside itself, then ran the real
  `interop_test.ps1` against it and watched the harness's transcript parser believe the forgery,
  reporting `runner: PASS, 999 assertions across 8 suites`. Only the separate exit-code check
  turned the run red. A checker that had followed the earlier version of this rule literally,
  grepping for `PASS:` and nothing else, would have passed a suite that failed.

  Better than either: **the runner emits `PASS` only as its final line, and checkers read the
  tail rather than grepping the whole transcript.** Grep matches a forgery anywhere in the
  output; a tail read does not.
- **Any bound a test runner enforces must be below the `--quit-after` it runs under**, or the
  harness exits successfully before the bound is reached and the bound is decorative.
- **Treat a passed sabotage suite as evidence about the modes tested, not about the runner.**
  When a later unit finds a new hole, add that mode to the list rather than treating the
  earlier verification as having been wrong. The verification was correct and incomplete,
  which is the normal state of every verification.
- **Prove the sabotage applied before you believe the green run.** M1b's verifier edited a Go
  file with a `perl` one-liner that silently did nothing, because the file has CRLF line endings
  and the pattern did not match. The suite then ran green **against unsabotaged code**, which
  reads exactly like "the test does not catch this". It caught itself with `git diff --stat`
  before reporting, and checked every later sabotage was applied before running it.

  A sabotage that fails to apply produces a false *finding*, not a false pass, which makes it the
  mirror image of everything else on this list and just as wrong. `git diff --stat` between
  editing and running costs nothing. **Every sabotage in this program's history that was worth
  anything was worth it because someone confirmed the break existed.**
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

**That rule was written and then immediately violated, so here is the sharper version.**
`PROTOCOL.md` was given the sentence "in M0 the queue always wins, in microseconds, because
frames are small and frequent", taken from the M0f writer's report. Its verifier probed a real
stalled peer and found the opposite: M0's frames are small but *infrequent*, since M0 has no
per-tick broadcasts and no heartbeat, so ordinary traffic loses that race and dies by timeout
minutes later. The race also turned out to have a third outcome nobody had named.

**Reproduce claims about a dependency's behaviour. Claims about our own code are cheaper to
trust.** That is the sharper cut, and it took three falsehoods to find. All three were about
something we did not write:

1. That a `move_to` could carry `NaN`. That was about Go's `encoding/json`, and JSON has no
   `NaN` literal.
2. That the send queue "always wins, in microseconds". That was about the server's timing under
   load conditions nobody had enumerated, and the opposite is true for M0's actual traffic.
3. That assigning `WebSocketPeer.write_mode` is a parse-time error. That was about Godot's
   parser, and it is a runtime error: the script loads fine and the failure happens later, so
   the process looks alive while nothing works.

An earlier version of this rule said to reproduce *quantitative* claims. That caught the second
one and would have missed the first and third, both of which are mechanism claims with no
number in them. The reliable signal is not the shape of the claim, it is who owns the behaviour.
"This function is only reachable from that goroutine" is about our code and a reader can settle
it. "This library rejects that input", "this engine fails at parse time", "this always finishes
in microseconds" are about someone else's code under conditions nobody enumerated, and they
belong in a probe before they belong in a contract file.

A worker asserting one of these is usually right about the *behaviour* and wrong about the
*mechanism*, which is the worst combination, because the symptom it describes really does
happen and that makes the explanation feel confirmed.

**M1f produced four more, all about `coder/websocket`, and the fourth landed inside the
correction for the third.** Behaviour right every time, mechanism wrong every time. The
sharpest form of the rule came out of it and is now in the code: **only a measurement separates
the mechanism that explains what you see from the one that produces it.** Two practical
corollaries, both paid for. Probing a dependency's *return value* does not probe its *side
effects*; M1f confirmed by probe that a write timeout is `errors.Is`-comparable, which was
correct and useless, because the claim it needed was about ordering. And reasoning about what
*we* pass a library says nothing about the contexts the library *derives*: `readPump` passes
`context.Background()`, yet the library builds its own five-second contexts for control frames,
which made a "this branch is unreachable" claim false and hid a slow client being logged as a
clean close.

**The structural answer is a test that pins the scenario, not a comment that explains it.** M1f
declined an end-to-end test on costed grounds a coordinator accepted; its verifier was asked to
show a mechanism rather than assert one and **built the test instead**, which settled it. When a
unit's correctness rests on a dependency's side effects, price the end-to-end test rather than
reasoning about the dependency a fourth time.

## The coordinator's fleet is part of the environment

**Never run a timing-sensitive verification concurrently with other Godot work.** This cost a
worker its acceptance criterion and cost me a false diagnosis.

`scripts/two_client_demo.ps1` schedules its phases on wall-clock deadlines but waits **15
rendered frames** inside each capture. Unloaded that is a quarter-second and invisible. With
several agents driving Godot at once, those fifteen frames stretch without bound, the second
capture of a phase lands after the walk has finished, and every displacement reads exactly 0.
`NOTES.md` had already recorded the class, from M0d: a frame budget is a machine-dependent
amount of wall time.

M1g's writer measured 8.2 seconds for a single client to boot and capture and concluded the
machine was slow. It was right about the number and could not see the cause, because **the cause
was the coordinator's own fleet**, which no worker can observe. Run on an idle machine
afterwards, the same commit passed in 21.7 seconds with the two `move_to` events 25 ticks apart,
against the 81 the worker saw.

Three rules:

- **Serialise Godot-driving agents when any of them is timing-sensitive.** Go tests and headless
  suites tolerate load; the windowed demo does not.
- **A worker's environment claim is scoped to what a worker can see.** "This machine is slow" is
  a hypothesis about a machine whose other tenants are invisible to it. Check your own fleet
  before believing it, and before letting a worker write it down.
- **Take the idle measurement yourself.** It is one command and it settles the question that a
  worker cannot settle from inside the load.

## Sizing a verification

A verifier is an agent with a budget like any other, and a check list is scope.

The M0b verification was written as one agent with eight checks covering re-runs, harness
sabotage, three engine-API claims, protocol conformance, the seam, merge mechanics, and a
hunt for server defects. It died on a session cap with one claim confirmed, and everything it
had learned went with it. Respawned as two agents, one asking "is it genuine" and one asking
"is it correct", both finished.

- **Split a verification when its checks exceed roughly four, or when they span re-running,
  reading, and adversarial probing at once.** Those are different activities with different
  costs, and bundling them makes a single expensive agent whose failure loses all of it.
- **Give each half a verdict of its own** rather than making one agent produce a single verdict
  over unrelated evidence. The merge decision is the coordinator's to assemble.
- **Tell each half explicitly what its sibling owns**, so neither pays for the other's work.
- A cap-hit is a scope problem. Respawn smaller, per the retry policy; retrying the same brief
  as-is buys another cap-hit.

## Three things the M0e verification taught

**A verifier's numbers should differ from the writer's, and that is evidence.** M0e's milestone
verifier measured 3.504 units of displacement at tick 22 where the writer reported 3.954 at tick
13. It read the discrepancy correctly: wall-clock capture timing differs per run, so a number
that changes between runs is being computed live rather than replayed from a fixture. **If a
verifier reproduces a writer's figures exactly, ask whether it re-ran anything or read the
transcript.** Identical numbers on a timing-dependent measurement are the suspicious outcome,
not the reassuring one.

**An inference is not an observation, especially about the headline claim.** M0e proved that
client B watches client A walk. The milestone sentence is "each sees the other walk", and the
reverse direction rested on both clients running the same program plus a suite that proves
watcher mechanics. That inference is sound. It was still an inference, standing in for the one
sentence the entire milestone is defined by, and closing it cost one follow-up message against a
worker that still had full context. **Where the deliverable is a sentence, verify the sentence,
not a proposition that implies it.**

**A verdict can be extended across a disjoint delta, but never assumed across any delta.** A new
head SHA voids a verdict; that rule stands and exists because a branch that moves after
verification is not the branch that was verified. But re-running a full verification for a
one-file follow-up is waste when that file is provably outside everything the verdict examined.
The honest middle: diff the new SHA against the verified one, confirm the change is disjoint
from what the verdict covered, re-verify only the part that moved, and record in the ledger both
SHAs and which half was re-run. **Extending requires showing the disjointness, not asserting
it.** If the delta touches anything the verdict reasoned about, the verdict is void and the
verification runs again.


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
   adversarial probing, split into two agents with a verdict each. *Sizing a verification*
   above has the rules.
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

## Lessons from M1

M1 was cut as five units and ran to ten unit PRs. Every addition came from a verifier finding
something real, never from the plan growing: a client assertion that blocked a sibling, a demo
that could not tell a frozen server from a live one, a panel that walked the player, a contract
decision nobody had implemented, and a test-only defect found while reading. That ratio is the
argument for the verification discipline. Five verifiers each invented a false pass nobody had
listed, and four of the five were real.

**A green suite hides whole classes of defect.** M1k's verifier invented a sabotage that left the
whole suite green while a live client walked on a chrome click, because every chrome test fed an
occupied inventory and nothing exercised the empty panel every player has at join. M1f's central
bug was found by `-race` under `-count=10` and reported no race at all. The WebSocket library
closes the connection from its own timer before `Write` returns, so the read pump condemned
`peer_gone` over the real cause.

**A demo that reads only client output passes a frozen server.** Every original assertion in
`two_client_demo.ps1` read a client's stdout or PNG. A verifier made the tick loop skip its
movement step, and the demo printed `TWO CLIENT DEMO OK` with displacements byte-identical to a
healthy run, because clients interpolate the polylines they are handed. Since M1g the demo reads
the event log and requires an `arrived` per player. Since M1j it also requires the arrival's tick
span to be plausible, because a server that crosses a whole path in one tick emits a
perfectly-formed `arrived`. `.claude/skills/verify-marque/SKILL.md` records what each demo asserts.

**Redirect the harnesses to a file. Do not pipe them.** `interop_test.ps1 | tail -40` sat for
fifteen minutes after the Godot runner had written its final `PASS:` line, with the server still
alive and the script's cleanup never reached. `> out.txt 2>&1` finished in about two minutes,
exit 0. Seen twice. The mechanism is not established and is not guessed at here.

**M1j's tick-skew finding.** Two clients anchor `TickClock.estimated_tick()` independently, at
their own `welcome` receipt, against their own monotonic clock. Two clients that believe they are
both "at tick N" can be there at real-world instants up to one tick apart.
`contested_pickup_demo.ps1` has three sync checks, not one: `:541` (client-side declared aim
ticks equal), `:718` (server-side `path_assigned` start ticks equal), and `:732` (resolve tick
equals loss tick). Measured on `main` after M1j:

| Check | Idle (n=21) | Loaded (n=6) |
|---|---|---|
| Clients' aim ticks differ by 1 (`:541`) | 15 of 21, never more | 3 of 6 |
| Server start ticks differ by 1 (`:718`) | 8 of 21, never more | 1 of 6 |
| Resolve/loss gap is 0 (`:732`) | 21 of 21 | 6 of 6 |
| Demo passes overall | 13 of 21 | 3 of 6 |

Load is not the cause. Client-side clock quantisation is, and it predicts a rate independent of
load. A run that fails on only `:541` or `:718` is this baseline, not a regression. Do not widen
a tolerance to make it pass. Paths starting a tick apart on equidistant spawns are a sequence, not
a contest, and the milestone sentence forbids a sequence. M2's heartbeat and the `tick-anchor-align`
branch are the two candidate fixes, and a 21-run measurement against this table decides between
them.

**The `:732` gap depends on join order.** `step()` resolves pending pickups in join order, so a
loser condemned on the winning tick (gap 0) has to be the later joiner. An earlier-joining loser
sees the item still live, finds itself out of range, and is condemned a tick later (gap 1). The
demo's loser is always the later joiner, which is why it measures gap 0 every run.

**Known flake, recorded so nobody debugs it twice.** `two_client_demo.ps1`'s still-camera
control is the sky-band check. It asserts byte-exactness over the top quarter of a
GPU-rendered frame. Failures cluster under GPU load right after heavy suites.
`DEMO pos` and path geometry can match a green merge-base while the sky band flips.
The control fails in the safe direction, never a false pass. Two consecutive
sky-band failures under load are still this flake. Call a product regression only
if an idle-machine control also fails the sky band, or if geometry differs.
Read `.claude/skills/verify-marque/SKILL.md` Known flake for the steps.

## Recipes and brief paste rules

Historical M2 cutting notes and forks stay below for context. Open milestones and units live in
Linear; do not treat PR lists or dispatch order as current program state.

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

Pass: exit 0 and last lines `TWO CLIENT DEMO OK` and `CONTESTED PICKUP DEMO OK`. The contested
demo has a known legitimate failure rate on `:541` and `:718` (the M1j table above). A run that
fails on only those lines is the baseline, not a regression; rerun up to three times. If
`two_client_demo.ps1` fails only on the sky-band still-camera control, that run is the Known
flake above, not a finding. The idle-machine control and the geometry comparison in the Known
flake paragraph decide whether the sky-band failure is a product regression. Any other failing
line is a finding.

### Forks decided while cutting M2, all revisitable

- **Token transport is the `session` URL query parameter**, server-issued, 128-bit random hex,
  never logged. Header transport also works in Godot 4.7.2 and was not chosen; one mechanism.
- **Only abrupt deaths suspend.** `closed` and `protocol_error` retire at once. Chosen for
  RuneScape's logout-versus-disconnect split, and because every peer in the Godot suites closes
  cleanly, so `main`'s interop suite keeps its immediate despawns. The shipped client quits
  without a close frame (`disconnect-despawn.md`, observed M1f), so a killed client suspends.
- **Grace is 400 ticks.** A number, parked as a Follow-up issue.
- **Resume of a still-connected player is refused, not superseded.** Supersede needs a
  server-to-client "do not reconnect" signal, which would be a new message or a close code the
  server does not send today. Half-open sockets therefore recover only when the OS surfaces the
  dead peer; how long that takes is a property of the TCP stack and nobody has measured it here.
- **Duplicates get no reply.** The restatements are the truth. A refused sequenced intent still
  advances `last_seq`.
- **No acks and no client replay.** `welcome.last_seq` is the cumulative restatement; a lost
  click is lost.
- **Heartbeat every 10 ticks, at the top of `step`, no log line.** Period on the wire as
  `welcome.heartbeat_ticks`.
- **Client re-anchors on every heartbeat that disagrees with its estimate**, logging each
  correction, and abandons after three missed heartbeats. Hysteresis was considered and buys
  nothing: the phase term makes the first heartbeat disagree by one in almost every session,
  and later corrections shift the anchor by latency jitter, about a centimetre of avatar.
- **Client strictness stays lenient** after reconnect exists.
- **Backoff 0.5 s doubling to 5 s, unbounded.** Numbers, parked by M2f.
- **No server-side ping liveness in M2.** Not needed for the milestone sentence.
- **Tokens come from `crypto/rand` and never enter the event log**, so replay diffs of the log
  stay deterministic.

### Found stale while cutting

- `client/scripts/tick_clock.gd:90` carries the same wrong "roughly one-way latency" sentence as
  `PROTOCOL.md`. The unmerged `tick-anchor-align` branch rewrites that comment; M2 units are
  forbidden from the file to avoid the conflict. Whoever closes that branch owns the comment.
