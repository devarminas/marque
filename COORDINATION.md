# Coordination playbook

How the coordinator runs this program. **Workers do not need this file and it is not pasted
into briefs.** It was carved out of `STANDING-ORDERS.md`, which had grown to 329 lines, most of
them lessons about brief-writing and verification that a worker has no use for while obeying.

`STANDING-ORDERS.md` is the worker contract and stays small enough to paste verbatim, which is
what it is for.

## Coordination, deliberately collapsed

M0 was seven units across two tracks. M1 was cut as five and is now nine, every addition opened
because a verifier found something real rather than because the plan grew. That is still under
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
10. **Open every worker brief with the `SKILL.md` read instruction, and gate on the playbook
    block.** Four M2 worker transcripts, grepped for `SKILL.md`, `playbooks/`, and
    `principle-*` reads: two of the four never opened a playbook, and one never opened the
    skill at all. The M2a writer's first call was `Skill poteto-mode`, which the skill
    refuses by design; it took the refusal as an answer, never read `SKILL.md` or a playbook,
    and reported in the brief's six "Report back" items, none of which asked what the
    playbook required. `no-comments` never ran, and PR #20 merged 206 comment lines in 388
    added production Go lines, 179 of 349 in `world.go`, which a human caught after the merge.
    The agent definition alone does not load the skill. Neither does a prompt that begins
    with `/poteto-mode`. A `poteto-agent` probed with that prefix on 2026-09-04 reported the
    skill text absent from its context and `poteto-mode` absent from its available-skills
    list, so do not retry it. The skill carries `disable-model-invocation`, which is why a
    subagent's own `Skill poteto-mode` call is refused and why the slash form does nothing for
    a subagent. The two compliant transcripts, the M2b writer and M2a verifier A, read
    `SKILL.md` as a file and then opened the playbook. Every brief must name
    `C:/Users/armin/.claude/skills/poteto-mode/SKILL.md`, tell the worker to read it in full
    as a file before any work (the Skill tool will refuse), to copy its matched playbook's
    steps into its todolist, and to end its report with the playbook block. The gate must ask
    for that block, every step done or `skip: <reason>`, because a brief's own report format
    otherwise displaces the checklist entirely.

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

---

# Program state

Moved here from `STANDING-ORDERS.md` because it is coordinator-facing history, not a worker
contract. A worker obeys the standing orders; it does not need to know which PR carried which
verdict. That file states it is kept short enough to paste cheaply, and the coordinator had
grown it by half with this material, which is the invariant this move restores.


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

## M1

**The milestone holds. Two Godot clients race for one item on the ground and exactly one gets
it, proven by observation.** Measured on `main` at `87f2a82` by the coordinator, not inferred:

```
==> server: player 1 took item 1 into slot 0 on tick 52; player 2 lost it on tick 52
==> server: the contest resolved on tick 52 and was lost on tick 52; gap 0 tick(s)
CONTESTED PICKUP DEMO OK
```

Nine units merged, each with a verdict in its PR body, which is the ledger.

| Unit | PR | Verdicts | What |
|---|---|---|---|
| M1c | #8 | `live-ui-verified`, `conformance-holds-with-findings` | The second registry: ground item bodies, green for a known kind and magenta for an unknown one |
| M1g | #9 | `live-ui-verified` | The demo asserts server state, plus the `verify-marque` skill |
| M1a | #10 | `unit-test-verified`, `conformance-holds-with-findings` | `Store`, ground items, inventory, `pickup`, contested resolution |
| M1h | #11 | `unit-test-verified` | Client stops asserting on a session-wide accumulator, and accepts a `null` list |
| M1b | #12 | `unit-test-verified` | `drop`, pickup's reverse transaction, and a new id every time |
| M1d | #13 | `live-ui-verified` | Clicking an item picks it up; the inventory panel |
| M1e | #14 | `live-ui-verified`, `sabotage-holds-with-findings` | **The milestone.** Two clients, one item, exactly one holder |
| M1k | #15 | `conformance-holds-with-findings`, `sabotage-holds-with-findings` | The inventory panel is opaque, and the test that clicked through it moved |
| M1f | #16 | `conformance-holds-with-findings`, `sabotage-holds-with-findings` | Classify a dead connection by cause, latch the first condemnation. Absorbed M1i |
| M1j | #17 | `sabotage-holds-with-findings` | Hardened both demos, corrected two documents, measured the three sync checks |

**M1j is closed.** It hardened both demos and corrected two documents. `two_client_demo.ps1` now
checks the arrival's tick against the path's, so a *teleporting* server no longer passes it merely
for finishing a walk; sabotaged with `distance := 1000.0`, caught. `contested_pickup_demo.ps1` now
asserts the loser's halt position is within `PickupRange` of the item rather than only what it did
not receive; sabotaged with a fixed `(50, 50)` halt, caught at 77.782 units. `SKILL.md` no longer
blames the frozen-server sabotage for a `DEMO TIMEOUT` it cannot produce — observed twice, by
M1j's own commit and again by its verifier, both a clean failure on `0 arrived event(s)` with
empty client stderr and no timeout. **Load is the remaining explanation and nobody has reproduced
it**, and the text says exactly that rather than asserting the positive. `features/contested-
pickup.md` no longer claims the sync ticks were identical on every run, which M1k had already
falsified by observing 32 against 33.

**The verifier caught the writer overstating its own mechanism, after an initial ready-to-merge
call, and the fix landed as a same-branch follow-up rather than a force-push.** The writer's
`:732` comment said a loser is condemned "at whatever distance it is still standing at,"
unconditionally. `resolvePickup` does test `!live` before range, but `step()`
resolves pending pickups in **join order**, and that's what actually decides the outcome: a loser
condemned on the winning tick (gap 0) has to be the *later* joiner. An earlier-joining loser would
see the item still live, find itself out of range, return unresolved, and be condemned a tick
later instead (gap 1). This demo's loser is always the later joiner, which is why the writer
measured gap 0 on all 8 of its skewed-start runs — but `:732` is not a general backstop for
`:718`, only a coincidence of this demo's fixed roles. The verifier proved the split with a
throwaway Go test against `resolvePickup`/`step`, run and deleted, `git diff --stat` clean before
and after. Fixed in `82da058`, shown disjoint from the verified `59ffb3d` before the verdict
extended across it.

**Two comment-cull PRs closed alongside M1j, unplanned but real.** A comment audit had already
found five false comments split across `server/` and `client/`, one citing a test
(`TestClassifiersDisagreeAboutTheSameDyingConnection`) that turned out to be a dangling reference
rather than a fabrication — it existed at `8cebda1` and was removed at `9e50b18` when a
replacement landed. `cleanup-go-comments` (PR #18) was verified by a token-stream lever
(`go/scanner` over both revisions, comments excluded, byte-identical) plus an independent `-race`
rerun; one commit-message overstatement and one over-cut true comment (`Hub.Close`'s lock-ordering
note) were restored in a follow-up commit. `cleanup-client-comments` (PR #19) was verified by a
hand read plus a scripted comment/whitespace stripper, and by rerunning `interop_test.ps1` on both
sides of the cull with an identical 573-assertion, 9-suite result and a line-for-line matching
assertion set.

**One unit is open, and it does not block: tick-anchor alignment.** `client`-only, briefed
directly against the baseline table below. Two clients anchor `TickClock.estimated_tick()`
independently, at their own `welcome` receipt, against their own monotonic clock, so two clients
that believe they are both "at tick N" can be there at real-world instants up to 150ms apart —
which is why `contested_pickup_demo.ps1` legitimately failed about 38% of idle-machine runs.
Acceptance is the same 21-run measurement below, same script, going from ~62% overall pass to
approximately 100%; no `server/` or `PROTOCOL.md` change, and M2's heartbeat and `seq` field stay
reserved.

**Three sync checks, not one, and the handover conflated them.** They are
`contested_pickup_demo.ps1:541` (client-side declared aim ticks equal), `:718` (server-side
`path_assigned` start ticks equal), and `:732` (resolve tick equals loss tick, gap 0). An earlier
handover said the aim check "can safely tolerate one tick". **Treat that as a hypothesis, because
it looks wrong for `:718`**: both players spawn equidistant, so paths starting a tick apart mean
arrivals a tick apart, and that run is a *sequence, not a contest* — which is what the milestone
sentence forbids and what `:732` would independently catch. M1k's writer saw `:718` fail once, at
32 against 33, **with a Go toolchain process running**, which raises the untested alternative that
the skew is load-induced and the honest fix is not a wider tolerance at all. Measure a
distribution, idle and loaded, before changing anything.

**What M1 cost beyond its plan.** It was cut as five units and ran to ten. Every addition came
from a verifier finding something real, never from the plan growing: a client assertion that
blocked a sibling, a demo that could not tell a frozen server from a live one, a panel that walks
the player, a contract decision nobody had implemented, and a test-only defect found while
reading. **That ratio is the argument for the verification discipline**, not the ceremony around
it. Five verifiers each invented a false pass nobody had listed, and four of the five were real.

**M1k and M1f kept the ratio.** M1k's verifier invented a sabotage that left the whole suite
green while a live client walked on a chrome click, because every chrome test fed an occupied
inventory and nothing exercised the empty panel every player has at join. M1f's central bug was
found by `-race` under `-count=10` and reported no race at all: the WebSocket library closes the
connection from its own timer before `Write` returns, so the read pump condemned `peer_gone` over
the real cause. Both were invisible to a green suite.

Two commands tell you the stack is alive. **Redirect them to a file; do not pipe them.**
`interop_test.ps1 | tail -40` sat for fifteen minutes after the Godot runner had already written
its own final `PASS:` line, with the server still alive and the script's cleanup never reached,
while `> out.txt 2>&1` finished in about two minutes, exit 0. A stale work directory from an
earlier session shows the same signature, so it is not a one-off. **The mechanism is not
established and should not be guessed at.**

- `powershell -ExecutionPolicy Bypass -File scripts/interop_test.ps1` builds the server, binds a
  free port, runs the whole Godot suite against a live `marqued`, and shuts it down. **573
  assertions across 9 suites** as of M1k merging, measured on `main`; INTERACTION 104/0,
  WIRING 95/0, INTEROP 91/0. This number goes stale every time a unit adds a suite, so treat it
  as "what it was last time somebody looked" and report the number you got.
- `CGO_ENABLED=1 go test -race ./...` from `server/`, with the PATH export in
  `STANDING-ORDERS.md`. Exit 0, zero data races, `internal/net` about 93 seconds.
- `powershell -ExecutionPolicy Bypass -File scripts/two_client_demo.ps1` runs two real windowed
  clients. **Read the next paragraph before you believe what it tells you.**

**`two_client_demo.ps1` now asserts server state, and did not before M1g.** It reads the event log
it used to delete, and per player id resolved from that client's own `DEMO joined` line it
requires a `path_assigned` spanning at least two units and an `arrived` that postdates
`start_tick` and lands within `1e-6` of that path's endpoint. It then ties the layers together,
comparing where the client drew a player against where the server says it stopped.

**Why that had to be added.** Every one of its roughly twenty original assertions read a client's
stdout or a client's PNG. A verifier made the tick loop skip its movement step, so the server
assigned and broadcast paths and never moved anybody, and **the demo printed `TWO CLIENT DEMO OK`
with displacements byte-identical to a healthy run.** Clients interpolate the polylines they are
handed, so a frozen server still produces moving pixels on every screen. Reproduced after the
fix: the frozen server passes every client-layer assertion and the nine-event log turns it red on
`the whole log holds 0 arrived event(s) for that player`.

M0's milestone verdict always stood, because M0e's verifier read the event log itself and the
interop suite carries ninety server-side assertions. The demo alone did not, and this file
described it as a milestone proof for a milestone and a half.

**The next false pass in the family was closed by M1j.** A *teleporting* server used to pass. With
`distance := 1000.0` the world crossed a whole path in one tick and emitted a perfectly-formed
`arrived`, and the demo printed OK. A 6.204-unit walk at `WalkSpeed` 3.0 on 150ms ticks takes 14
ticks and every healthy run shows exactly 14, and the demo now asserts that span is **plausible**
rather than merely that the server *finished* the walk. Sabotaged and caught; see the M1j entry
above.

**The baseline measurement that unlocked the `:541`/`:718` decision, and that tick-anchor
alignment's acceptance criterion is measured against:**

| Check | M1j baseline (n=21, idle) | M1j baseline (n=6, loaded) |
|---|---|---|
| Clients' aim ticks differ by 1 (`:541`) | 15 of 21, never more | 3 of 6 |
| Server start ticks differ by 1 (`:718`) | 8 of 21, never more | 1 of 6 |
| Resolve/loss gap is 0 (`:732`) | 21 of 21 | 6 of 6 |
| Demo passes overall | 13 of 21 (~62%) | 3 of 6 |

Loaded rates are lower than idle, not higher, which at n=6 is no signal — load is not the cause,
client-side clock quantization is, and it predicts a rate independent of load.

**The demo is load-fragile and must run on an idle machine.** See *The coordinator's fleet is part
of the environment* above.

**Known flake, recorded so nobody debugs it twice.** The demo's still-camera control asserts
byte-exactness over the top quarter of a GPU-rendered frame. One flip was observed on a fully
static frame across eighteen measured windows, explicable only by render nondeterminism. It
fails in the safe direction, never a false pass. If the demo fails on only "the background is
not a control" with a still fraction near zero, rerun before investigating.

**The `-race` gap is closed.** The human installed LLVM-MinGW UCRT on 2026-09-02 and the
re-verification pass the standing orders called for is **done**, because it turned out to be one
command rather than a unit: `CGO_ENABLED=1 go test -race ./...` from `server/` on `main` at
`06e542e` exits 0 across all three packages with zero data races, `internal/net` alone taking 86
seconds under instrumentation. Every merged Go unit is covered by that single run, which is what
"re-verify every merged Go unit in a single pass" asked for. See *Verified tooling* in
`STANDING-ORDERS.md` for the PATH and the standing recipe.

The single-goroutine-ownership invariant is therefore no longer verified only by construction.
It is still not *proved*: a clean run means no race was detected along the paths the tests
exercise, and the tests are the limit.

**Outstanding, needs the human, not blocking anything.** `FOLLOW-UPS.md` holds everything parked
for you, including four things a first playtest will ask about.

## M2

**The milestone sentence.** A client whose socket dies mid-action comes back as the same player
with the same inventory, and an intent it sends twice is applied once. Cut on 2026-09-03 against
`main` at `e809533`. Six units, three Go and three Godot, no unit touching both. Nothing here
depends on the unmerged `tick-anchor-align` branch (`9974695`) and nothing folds its work in;
M2d says where the two meet.

**Progress, 2026-09-04.** M2a is merged. Abrupt socket deaths (`peer_gone`, `slow_client`) now
suspend the player for `ResumeGraceTicks = 400` with no `despawn`; clean closes retire at once.
Both windowed demos end with `player_suspended` and no `despawn`. M2b and M2c are written and
pushed with no verdict on their heads; the session ended before verifiers ran. Each PR body
states what is owed. Two findings against `main` and a pending M2a comment cull are in
`FOLLOW-UPS.md`, *Found while dispatching M2*.

| Unit | PR | Head | Verdicts | State |
|---|---|---|---|---|
| M2a | #20 | `53470da` | `genuine-verified` at `27c602d` and `conformance-with-findings` at `27c602d`, both `fable`. Five findings fixed at `53470da`; the delta was shown by diff to contain no non-test Go file. | Merged, `496ef5b` |
| M2b | #22 | `a6fc9fb` | none. Writer's Recipe G and H green, one sabotage red. | Awaiting both verifiers |
| M2c | #21 | `2e198e4` | `genuine-verified` and `conformance-with-findings` at `0c0fd96`, both `fable`, void for the head: findings fixes, a `main` merge, and a comment cull changed non-test GDScript after them. | Awaiting delta verification |

**Dispatch order.** M2a, M2b, M2c, M2d, M2e, M2f. M2c is client-side and independent of M2a and
M2b, so it may run alongside them (headless suites tolerate load). Every other unit waits for the
one it names. Only one Godot-driving agent at a time when a windowed demo is in the recipe.

**Every brief, in addition to its block below.** Paste `STANDING-ORDERS.md` verbatim and name its
SHA. Worktree under `C:\Users\armin\Documents\Projects\game\`, branch from current `origin/main`,
and run `git merge origin/main` into the branch before writing anything. Test files are the
writer's. Read `PROTOCOL.md` at the branch's SHA rather than any summary here; where a block
below states a rule, the block is the coordinator's decision and the writer copies it into
`PROTOCOL.md` first, then codes against the file. A verify recipe passes only on exit 0 **and**
the marker read from the last line of the redirected output. Redirect, never pipe.

### The three recipes, named once

**Recipe G.** From `server/`, Git Bash:

    export PATH="/c/Users/armin/AppData/Local/Microsoft/WinGet/Packages/MartinStorsjo.LLVM-MinGW.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe/llvm-mingw-20260616-ucrt-x86_64/bin:$PATH"
    CGO_ENABLED=1 go test -race ./... > ../out-race.txt 2>&1; echo EXIT=$?; tail -5 ../out-race.txt

Pass: `EXIT=0`, an `ok` line for each of `internal/game`, `internal/gamelog`, `internal/net`,
no `DATA RACE`, no `FAIL` anywhere in `out-race.txt`. `internal/net` takes about 90 seconds.
Toolchain reproduced on 2026-09-03: `game` and `gamelog` under `-race`, exit 0.

**Recipe H.** From the repo root, PowerShell:

    powershell -ExecutionPolicy Bypass -File scripts/interop_test.ps1 > out-interop.txt 2>&1; echo $LASTEXITCODE
    Get-Content out-interop.txt -Tail 3

Pass: exit 0, last line `INTEROP OK`, and inside the transcript `INTEROP RAN: N assertions, 0
failed`, `WIRING RAN: N assertions, 0 failed`, and `PASS: N assertion(s) held across M suite(s)`
with N at least the 573 across 9 suites measured on `main` at M1k. Report the numbers you got. The
transcript also prints the server's whole event log under `--- marqued event log ---`; several
acceptance criteria below are read from it.

**Recipe W.** From the repo root, PowerShell, idle machine, one demo at a time:

    powershell -ExecutionPolicy Bypass -File scripts/two_client_demo.ps1 > out-two.txt 2>&1; echo $LASTEXITCODE; Get-Content out-two.txt -Tail 3
    powershell -ExecutionPolicy Bypass -File scripts/contested_pickup_demo.ps1 > out-contested.txt 2>&1; echo $LASTEXITCODE; Get-Content out-contested.txt -Tail 3

Pass: exit 0 and last lines `TWO CLIENT DEMO OK` and `CONTESTED PICKUP DEMO OK`. The contested
demo has a known legitimate failure rate near 38% on `:541` and `:718` (the M1j table above). A
run that fails on only those lines is the baseline, not a regression; rerun up to three times.
Any other failing line is a finding.

### M2a. A player outlives its socket

**Goal.** A connection presenting the session token from an earlier `welcome` resumes that player
with the same id, position, inventory and pending pickup, if the earlier socket died abruptly
within the grace; other clients see neither a `despawn` nor a `spawn` across it.

**Scope.** Go only. `server/internal/net/hub.go` (read the `session` URL query parameter at
upgrade, expose it on `Conn`), `server/internal/net/protocol.go` (`Welcome.Session`, one new
disconnect reason), `server/internal/game/world.go`, `server/internal/game/items.go` where the
player shape forces it, `server/cmd/marqued/main.go` only if the grace needs wiring, tests under
`server/internal/net/` and `server/internal/game/`. `PROTOCOL.md`. `FOLLOW-UPS.md` (the grace as a
number; correct the "inventory is deleted when they disconnect" sentence under *Items and
pickup*). `.claude/skills/verify-marque/features/disconnect-despawn.md` (the on-screen despawn
after killing a client now arrives after the grace).

**Prefactor first, as its own commit, Recipe G green at that commit.** A player becomes a durable
entity and the connection becomes a field on it. `players` keyed by `PlayerID`, a `byConn` index,
`bySession` index, `order` holding players not connections, `send` and `broadcast` skipping a
player whose connection is nil. Behaviour-preserving; the existing suite is the proof. Then the
feature commit.

**Data shape.** `player {id, session string, pos, remaining, pending, conn *Conn (nil while
suspended), expiresTick int64 (0 while connected), lastSeq (M2b, not here)}`.

**Rules, copied into `PROTOCOL.md` before coding.**

- `welcome.session` is an opaque string, 32 hex characters from `crypto/rand`, one per player,
  the same across every resume of that player, never written to the event log.
- A client presents it as the `session` query parameter of the WebSocket URL
  (`ws://host/ws?session=<token>`). **Verified 2026-09-03** against a stdlib Go handler: Godot
  4.7.2 `WebSocketPeer.connect_to_url("ws://.../ws?session=qry123")` arrives with
  `r.URL.RawQuery == "session=qry123"`. (`handshake_headers` also exists and also arrives; not
  used, one mechanism only.) A Go test dials the same way.
- Deaths split by cause, never by detail. `closed` and `protocol_error` retire the player at once,
  exactly as today (despawn broadcast, inventory deleted). `peer_gone` and `slow_client` suspend
  the player for `ResumeGraceTicks = 400` (60 s at 150 ms): the body stays in the world, the
  walk finishes, a pending pickup resolves into the kept inventory, no `despawn`. Expiry is
  checked in `step`, on the tick counter, never on wall-clock, and retires the player as today.
  `server_shutdown` needs no rule. RuneScape is the tiebreaker: a logout removes you at once, a
  dropped connection leaves your character standing for a while.
- Resume. A connection presenting a suspended player's token receives the ordinary atomic
  welcome step: `welcome` with the same `you` and `session`, the world, its own in-flight path
  among the replays, then its `inventory`. No `spawn` is broadcast; everyone already has the body.
- A token whose player is still connected is **refused**, not superseded. The new connection
  gets `{"error":{"msg":"session is still connected"}}` (no `re`) and is closed behind it with a
  new latched reason `refused`. No player is created, no `client_connected` is logged for it. The
  old connection is untouched. RuneScape's "already logged in" answer; supersede would need a
  server-to-client "do not reconnect" signal that does not exist yet. **Revisitable.**
- An unknown or expired token is a fresh join, logged. The client can tell, because `you` and
  `session` differ from what it held.
- Log vocabulary, new events with their own field sets, no field added to an existing event:
  `player_suspended {player, expires_tick}`, `player_resumed {player, remote}`,
  `player_expired {player}`, `resume_refused {remote}`, `resume_unknown {remote}`.
  `client_disconnected` is still logged for every socket death with its latched reason, as today.
- The `refused` row joins the reason table in *Which reason is authoritative*, marked M2a. It is
  a reason the world latches at the door and never logs under `client_disconnected`, because the
  world never admitted the connection.
- The status line at the top of `PROTOCOL.md` still says M1 is unimplemented. Correct it: M0 and
  M1 shipped, M2 in progress, each **M2** marker names the unit that discharges it.

**Discharges.** *Identity* M2 paragraph. *welcome* "repeated `welcome`" paragraph becomes true on
the wire. *When the connection dies*, server half. Reason table. Status line.

**Acceptance.** Each is a Go test against the real harness (`newHarness`, `dial`, `destroy`,
`close`, `awaitEvents`) unless it says otherwise. Each names what a failure shows.

1. Two players' `welcome.session` values are 32 hex characters and differ. Failure: a constant
   or empty token, which makes every later check vacuous.
2. A dials, `destroy()`s (abrupt). B receives no `despawn` for the silence window. A2 dials with
   `?session=<A's token>`. A2's `welcome.you == A's you`, same `session`; B receives no `spawn`;
   the log has `player_suspended` then `player_resumed` for that id and no `player_expired`.
   Failure: a fresh `you`, or B seeing a despawn or spawn.
3. A picks up the seeded acorn and holds it, then `destroy()`s. A2 resumes and its `inventory`
   restatement holds `acorn` in slot 0. Failure: empty slots, which is the inventory dying with
   the socket.
4. A is mid-walk when destroyed. A2's welcome step includes a re-anchored `path` for `you`.
   Failure: no path for `you`, leaving the resumed client standing at a stale position.
5. With the grace shortened for the test, A destroyed; after the grace `player_expired` is
   logged, B sees `despawn`, and A2 with the stale token gets a fresh `you` with `resume_unknown`
   logged. Failure: the ghost never leaves, or the stale token resurrects it.
6. A `close()`s cleanly. `despawn` at once, `client_disconnected reason=closed`, no
   `player_suspended`. `TestDisconnectDespawns` and `TestPickupSurvivesTheClientLeavingMidWalk`
   keep passing unchanged. Failure: a clean logout lingering for 60 s.
7. A connected; A2 presents A's token. A2 receives the `error`, then the socket closes; A's next
   `moveTo` still yields a `path`; `resume_refused` logged, no `client_connected` for A2.
   Failure: A2 admitted as a second body, or A evicted.
8. Frames on a connection the world no longer knows are still `frame_dropped unknown_sender`.
9. Recipe G exit 0, no race, including the resume path under `-race` (two goroutines' worth of
   hub events for one player).
10. Recipe H green and unchanged in count. The pre-M2 Godot client ignores `session` under rule
    2, and every peer in `test_interop.gd` closes cleanly, so it still sees immediate despawns.

**Verify.** Recipe G. Recipe H. Verifier reads `PROTOCOL.md` against the tests (conformance) and
tries at least one sabotage the writer did not list; two candidates: make suspension retire
immediately (2 must go red), and make tokens constant (1 must go red).

**Forbidden.** No merge to `main`. No `client/**`. No `scripts/*.ps1`. No `NOTES.md`,
`STANDING-ORDERS.md`, `COORDINATION.md`, `HANDOFF.md` (all at `e809533`, the coordinator's). No
`seq` or `last_seq` (M2b). No heartbeat (M2d). No supersede. No server-side ping. No new
client-to-server message. Tick rate stays 150 ms. Do not read or merge `tick-anchor-align`.

**Depends on.** Nothing. First unit.

### M2b. Sequence numbers and dedupe

**Goal.** An intent carrying `seq` is applied at most once per player across connections, and
`welcome.last_seq` tells a client where its numbering stands.

**Scope.** Go only. `server/internal/net/protocol.go` (parse `seq` once at the envelope, never
per message), `server/internal/game/world.go` (one gate in `handleFrame` before dispatch,
`lastSeq` on the durable player, `Welcome.LastSeq`), intent log events gain `seq`, tests.
`PROTOCOL.md`.

**Rules, copied into `PROTOCOL.md` before coding.**

- `seq` is an optional integer, at least 1, on any client-to-server body.
- Absent: unsequenced, applied as today. Compatibility with every client built before M2e.
- `seq <= last_seq`: a duplicate. Logged `intent_duplicate {player, re, seq, last_seq}`, not
  applied, **no reply**. The client learns the truth from `welcome` and `inventory` restatements,
  not from an answer to a retry.
- `seq > last_seq`: applied, and `last_seq = seq` even when the intent is then refused. A refused
  intent was received and decided; its retry would be refused again.
- `seq` of 0, negative, fractional, or not a number: `malformed_json` refusal carrying `re`, the
  connection kept.
- `last_seq` is per player, 0 at a fresh join, survives suspension and resume, and rides in
  `welcome.last_seq` on every `welcome`.
- No acks. `last_seq` is the cumulative restatement, which is all a client that does not replay
  needs. **Revisitable** if a client ever replays.
- `move_to`, `pickup`, `drop` log events carry `seq` when the frame did.

**Discharges.** *move_to* M2 paragraph (as a *Sequence numbers* subsection). `welcome.last_seq`.
*Deliberately absent* "No sequence numbers or acks" rewritten: sequence numbers present, acks
absent by decision.

**Acceptance.**

1. `drop seq=5` sent twice for the same slot: exactly one `item_spawn` broadcast, one
   `inventory`, one `drop` log event with `seq:5`, one `intent_duplicate`, no `error` frame.
   Failure: two item spawns, which is the dupe the milestone exists to prevent.
2. `pickup seq=1` resolves; A `destroy()`s; A2 resumes with `welcome.last_seq == 1`; A2 resends
   `pickup seq=1`: `intent_duplicate`, inventory still one acorn in one slot, no second `pickup`
   log event. Failure: `last_seq` 0, or a `pickup_rejected unknown_item`, which means it was
   applied again and refused.
3. `move_to seq=3`, then `move_to seq=2`: one path. Then `seq=10`: applied (gaps accepted).
4. An unsequenced `move_to` after `seq=10` is applied and `last_seq` stays 10.
5. `seq:0`, `seq:-1`, `seq:1.5`, `seq:"7"` each yield `error re=move_to`, connection open,
   `move_to_rejected reason=malformed_json`.
6. An out-of-bounds `move_to seq=8` is refused and `last_seq` becomes 8 (visible on the next
   resumed welcome).
7. `TestReservedFieldsAreIgnored` still passes: `seq:17` is applied, not ignored.
8. Recipe G exit 0, no race. Recipe H green and unchanged in count.

**Verify.** Recipe G. Recipe H. Conformance read of `PROTOCOL.md` against the tests. Sabotage
candidate: gate after dispatch instead of before (1 must go red).

**Forbidden.** No merge to `main`. No `client/**`. No `scripts/`. No heartbeat. No acks. No
scheduling docs (`e809533`).

**Depends on.** M2a merged. `lastSeq` lives on the player that survives the connection.

### M2c. The client hears the heartbeat, before anyone sends one

**Goal.** A client receiving `{"tick":{"t":N}}` re-anchors its clock at receipt and logs the
correction; a client told `heartbeat_ticks` in `welcome` abandons a socket that stays silent for
three heartbeats; `tick` stops being an unknown key.

**Why client-first.** `client/tests/test_interop.gd:344` and `:475` use `tick` as the canonical
unknown key. A server that sends heartbeats before this lands turns `main`'s interop suite red,
and the server unit cannot touch client tests. This is the M1c shape: the client half against the
spec, verified by fed frames, before the server sends anything.

**Scope.** Godot only. `client/scripts/net_client.gd` (decode `tick` into a `tick_received(t)`
signal; parse `welcome.heartbeat_ticks`, absent means 0; an `abandon()` that drops the peer
without a close frame and still emits `disconnected`), `client/scripts/session.gd` (re-anchor
through the existing `_clock.anchor(t, _tick_ms)`, log
`session: clock corrected by %+d tick(s) at heartbeat %d`, the liveness timer), tests under
`client/tests/` (decode in a tree-free suite, re-anchor and liveness in a fed-frame scene suite,
the two interop probes moved to an invented key). `PROTOCOL.md` *Clock*, a client paragraph only.

**Rules, copied into `PROTOCOL.md` before coding.**

- On `tick`, if `t` differs from `estimated_tick()` at receipt, re-anchor at `t` and log the
  signed delta. If equal, do nothing and log nothing. A `tick` before `welcome` is logged and
  ignored; a `tick` without a numeric `t` is dropped with `push_error` and the connection kept.
- Liveness. With `heartbeat_ticks > 0`, if no `tick` arrives within
  `3 * heartbeat_ticks * tick_ms` ms of the last tick-bearing frame (`welcome` counts), log loudly
  and abandon the socket. No close frame: under M2a a close frame is a logout, and an abandoned
  socket is `peer_gone`, which suspends. With `heartbeat_ticks` absent or 0, liveness is off. In
  this unit the session still does not reconnect afterwards; that is M2f.

**Discharges.** *Clock*, the client's side of the M2 heartbeat paragraph. The server's side stays
reserved for M2d.

**Acceptance.**

1. Fed frames: `welcome tick=100 tick_ms=150`, then `tick t=101` fed within the same tick's
   wall time. The correction line reads `+1` and `estimated_tick()` reads 101 immediately after.
   A second identical `tick t=101` logs nothing. Failure: no correction line, or the estimate
   still 100.
2. Fed frames: `tick` before `welcome` logged and ignored; `{"tick":{}}` and `{"tick":{"t":"x"}}`
   dropped with `push_error`; a following `spawn` still applies.
3. Fed frames: `welcome heartbeat_ticks=2 tick_ms=150`, no `tick` after it. Within about 900 ms
   plus a frame the session logs the dead-server line and `net.is_open()` is false. With
   `heartbeat_ticks` absent, nothing happens for 2 s. Failure: liveness firing with the field
   absent, which would kill every session against a pre-M2d server.
4. `test_interop.gd:344` and `:475` use a key that is not `tick`, and `unknown_message` no
   longer fires for `tick`.
5. Live half of the interop suite: one peer `abandon()`s its socket after `welcome`. The
   transcript's `marqued event log` shows `client_disconnected` for that peer's id with
   `reason=peer_gone detail=read_error`. Every other peer closes cleanly and logs `closed`, so
   the line is unambiguous. **This is the probe M2f depends on.** Failure: `closed` for that id,
   which means Godot flushed a close frame and M2f cannot stage an abrupt death this way; report
   it, do not work around it.
6. Recipe H green; the offline runner green.

**Verify.** Recipe H. Offline:

    cmd /c "godot --headless --path client --script res://tests/run_tests.gd --quit-after 900 > out-headless.txt 2>&1"; echo $LASTEXITCODE; Get-Content out-headless.txt -Tail 2

exit 0 and last line `PASS: N assertion(s) held across M suite(s)`. Read the interop transcript's
event log for criterion 5. No windowed demo: no server sends `tick` yet, so the clock is only
re-anchored by fed frames.

**Forbidden.** No merge to `main`. No `server/**`. No `scripts/`. No server-side heartbeat text in
`PROTOCOL.md`. No `client/scripts/tick_clock.gd`, `client/scripts/pickup_demo.gd`,
`client/scripts/polyline_walker.gd` (the first two are rewritten by unmerged `tick-anchor-align`
at `9974695`; `anchor()` already re-anchors, so nothing here needs them). No reconnect (M2f). No
`seq` (M2e). No scheduling docs (`e809533`).

**Depends on.** Nothing. May run alongside M2a and M2b.

### M2d. The server sends the heartbeat and the Clock section tells the truth

**Goal.** The server broadcasts `{"tick":{"t":N}}` at the top of every tenth tick, tells clients
the period in `welcome.heartbeat_ticks`, and `PROTOCOL.md`'s *Clock* section states the client's
real estimate error.

**Scope.** Go only. `server/internal/game/world.go` (`HeartbeatEveryTicks = 10`, emission in
`step` right after `w.tick++` and before movement, to connected players only),
`server/internal/net/protocol.go` (`Tick` message, `Welcome.HeartbeatTicks`), tests.
`PROTOCOL.md`. `FOLLOW-UPS.md` (the period as a number; delete the *Lost rationale* Clock entry,
which this unit makes moot).

**Rules, copied into `PROTOCOL.md` before coding.**

- `t` is the tick being stepped. Emitted when `tick % HeartbeatEveryTicks == 0`, so a reader can
  align heartbeats against `arrived.t` and `start_tick` by arithmetic. No log line per heartbeat.
- `welcome.heartbeat_ticks` carries the period, for `inventory.size`'s reason: the client uses
  the number it is told, never a second copy.
- The corrected *Clock* sentence. A `welcome`-anchored estimate lags the server by one-way
  latency **plus a per-client phase term uniform in `[0, tick_ms)`**, because `welcome` is
  composed on the event arm of `Run`, anywhere inside a tick. A heartbeat-anchored estimate has
  no phase term, because the frame is composed at the top of `step`; what remains is one-way
  latency plus the client's poll quantisation. Consequence, stated: the first heartbeat after
  `welcome` corrects a client by `+1` in almost every session, and two clients reading the same
  tick number are not reading it at the same instant until a heartbeat has anchored both.
- *Which reason is authoritative*: the heartbeat adds one frame per 1.5 s per client, far below
  the thirteen frames per second at which the queue detector was measured to win, so the timeout
  branch stays the ordinary detector. Nothing here re-measures it; say so.

**Discharges.** *Clock* M2 heartbeat paragraph, server side, and the wrong lag sentence.
*Deliberately absent* "No heartbeat". The *Which reason is authoritative* revisit note.

**Acceptance.**

1. A client receives `tick` frames whose `t` values are strictly increasing multiples of
   `HeartbeatEveryTicks`, each pair differing by exactly `HeartbeatEveryTicks`, the first
   greater than `welcome.tick`; `welcome.heartbeat_ticks == 10`. Failure: a `t` that is not a
   multiple of 10, which means emission is not at the tick boundary.
2. A suspended player (M2a) is sent nothing and nothing panics on its nil connection.
3. Recipe G exit 0, no race.
4. Recipe H green with the M2c client on `main`. In the transcript's Godot stdout, at least one
   wiring-suite session logs `session: clock corrected by +1 tick(s)` on its first heartbeat, and
   no correction has magnitude 2 or more. Failure: no correction line at all (the heartbeat never
   reached a session, or is not anchored at the boundary), or a magnitude of 2 or more
   (something beyond the phase term is wrong).
5. Recipe W, both demos, idle machine. Exit 0 with markers; every walk span the demos assert
   stays plausible. Failure: a displacement or arrival-span assertion, which means re-anchoring
   moved the walkers.

**Verify.** Recipe G. Recipe H, then read the transcript for criterion 4. Recipe W, alone on the
machine. Verifier's conformance read covers the new *Clock* text against `world.go:Run` and
`step`, since the sentence is a claim about our own code and a reader can settle it.

**After merge, the coordinator's measurement, not this unit's.** Rerun `contested_pickup_demo.ps1`
21 times on an idle machine and compare with the M1j table above. Hypothesis: `:541` skew falls
from 15 of 21 to about 2 of 21 (Godot's roughly 17 ms poll against a 150 ms tick), not to zero.
If the pass rate is near 100%, `tick-anchor-align` is redundant and closes unmerged. If not, its
shared-moment approach still earns its place and should be rebased onto the heartbeat anchor.
The table decides, not the argument.

**Forbidden.** No merge to `main`. No `client/**`. No `scripts/`. No server-side ping or pong
liveness. No change to the 64-frame buffer or the write timeout. No scheduling docs (`e809533`).

**Depends on.** M2c merged (or Recipe H turns red on `tick`). M2a merged (suspended players
exist and broadcast must skip them). M2b will be on `main` by then and is not required.

### M2e. The client stamps seq

**Goal.** Every intent the client sends carries `seq`, numbered from `welcome.last_seq + 1`, so a
repeated intent is deduped by the server.

**Scope.** Godot only. `client/scripts/net_client.gd` (a counter; `seq` stamped in one place on
the way out; `welcome.last_seq` parsed, absent means 0; a `send_frame(Dictionary)` for tests is
acceptable, the frame builders are already public for the same reason), `client/scripts/session.gd`
only if a signal changes, tests (`client/tests/test_item_protocol.gd` for frames,
`client/tests/test_interop.gd` live half for the dedupe). `PROTOCOL.md`, one client sentence under
*Sequence numbers*.

**Rules.** The counter restarts from `last_seq` on every `welcome`. The client never replays an
intent after a reconnect; a click in flight when the socket died is lost, as it is in RuneScape,
and `welcome` plus `inventory` are the truth. **Revisitable**, using `last_seq` as the cumulative
ack, if a lost click ever matters.

**Acceptance.**

1. Headless: three consecutive frames carry `seq` 1, 2, 3. After a `welcome` with `last_seq: 7`
   the next frame carries 8. After a `welcome` without `last_seq`, the next carries 1. Failure:
   a frame without `seq`, or a counter that ignores the restatement.
2. Live: the interop transcript's event log shows `seq` on every `move_to`, `pickup`, `drop` line
   from the suite's peers, ascending per player id. Failure: an intent line without `seq`.
3. Live: the same `move_to` frame sent twice with the same `seq` yields exactly one `path` in the
   window, and the event log shows one `intent_duplicate` for that player.
4. Recipe H green; offline runner green.

**Verify.** Recipe H, then read the transcript for 2 and 3. The offline runner command from M2c.

**Forbidden.** No merge to `main`. No `server/**`. No `scripts/`. No reconnect. No intent replay.
No `tick_clock.gd`, `pickup_demo.gd`. No scheduling docs (`e809533`).

**Depends on.** M2b merged.

### M2f. The client reconnects and resumes

**Goal.** A client whose socket dies reconnects with backoff, presents its session token,
rebuilds the world from the second `welcome`, and logs whether it came back as itself.

**Scope.** Godot only. `client/scripts/net_client.gd` (a new connection is allowed after
`disconnected`; the URL builder appends `?session=<token>`), `client/scripts/session.gd` (keep the
base URL and token; schedule reconnects at 0.5 s doubling to a 5 s cap, unbounded; on the second
`welcome` compare `you` and `session` and log `session: resumed as %d` or
`session: identity lost, rejoined as %d`; the M2c abandon path feeds this), tests in
`client/tests/test_wiring.gd` (session-level) and `client/tests/test_interop.gd` (wire-level).
`PROTOCOL.md` (*When the connection dies*, client half; *Compatibility*, the client-strictness
revisit; *welcome*, mark the second-welcome behaviour shipped). `FOLLOW-UPS.md` (backoff numbers).
`.claude/skills/verify-marque/features/disconnect-despawn.md` (`leave-freeze` becomes freeze then
reconnect).

**Rules, copied into `PROTOCOL.md` before coding.**

- The client never sends a close frame when it believes the server is gone. A close frame is a
  logout (M2a). It abandons, then reconnects.
- The world stays drawn between attempts. Freeze-and-announce still beats false-and-silent, and
  now the freeze ends.
- Client strictness, revisited and kept: a malformed server frame is still logged and dropped
  with the connection kept. A reconnect costs a full rebuild, so it is not the cheap recovery
  that would license being stricter. **Revisitable.**
- No intent replay (M2e).

**Discharges.** *When the connection dies*, client half. *Compatibility* revisit sentence.
*welcome* second-welcome paragraph, client side shipped.

**Acceptance.**

1. Live, wire-level (`test_interop.gd`): A joins, B joins, A `abandon()`s. B sees no `despawn`
   for one second. A reconnects with `?session=<token>`. A's second `welcome.you` equals its
   first; B never receives a `spawn` for A's id; A's second welcome lists B; an `inventory`
   follows it. Failure: a new `you`, or B seeing A leave and rejoin.
2. Live, session-level (`test_wiring.gd`): a session whose net is abandoned reconnects by itself.
   Within 2 s `has_joined()` is true with the same `own_id()`, the other client's body exists
   again under `RemotePlayers`, and the inventory panel was cleared and refilled. Failure: no
   reconnect, or a different id.
3. Live: a session whose net closed cleanly (which retired the player) reconnects with its stale
   token, rejoins with a new `own_id()`, and logs `identity lost`; the transcript's event log
   shows `resume_unknown`.
4. Offline: against a dead URL the reconnect delays observed are about 0.5, 1, 2, 4, 5, 5 s
   (assert on a signal or log line per attempt), and the bodies are not freed between attempts.
5. Recipe H green; offline runner green.
6. Recipe W, both demos, idle machine: exit 0 with markers. The shipped client quits without a
   close frame, so the event log now shows `player_suspended` after each `client_disconnected
   reason=peer_gone`; the demos' assertions do not read those lines and must not start to.

**Verify.** Recipe H, then read the transcript for 1 to 3. Offline runner. Recipe W, alone on the
machine. Verifier sabotage candidate: make the reconnect omit the token (1 and 2 must go red on
`you`).

**Forbidden.** No merge to `main`. No `server/**`. No `scripts/`. No intent replay. No reconnect
UI or scene change beyond what a log line needs. No `tick_clock.gd`, `pickup_demo.gd`. No
scheduling docs (`e809533`).

**Depends on.** M2a (resume), M2c (abandon and liveness), M2e (both edit `net_client.gd`;
sequential, not a semantic dependency). M2d for the liveness-triggered path to fire live.

### Forks decided while cutting, all revisitable

- **Token transport is the `session` URL query parameter**, server-issued, 128-bit random hex,
  never logged. Header transport also works in Godot 4.7.2 and was not chosen; one mechanism.
- **Only abrupt deaths suspend.** `closed` and `protocol_error` retire at once. Chosen for
  RuneScape's logout-versus-disconnect split, and because every peer in the Godot suites closes
  cleanly, so `main`'s interop suite keeps its immediate despawns. The shipped client quits
  without a close frame (`disconnect-despawn.md`, observed M1f), so a killed client suspends.
- **Grace is 400 ticks.** A number, parked in `FOLLOW-UPS.md` by M2a.
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

- `PROTOCOL.md`'s status line says M1 is specified and unimplemented. M2a corrects it.
- `.claude/skills/verify-marque/SKILL.md` says `go test -race` is unavailable and quotes 443
  assertions across 8 suites. Both are stale (`STANDING-ORDERS.md`, *Verified tooling*; the M1k
  count is 573 across 9). Not M2's to fix; a coordinator sweep, or `maintain-verification-skill`.
- `client/scripts/tick_clock.gd:90` carries the same wrong "roughly one-way latency" sentence as
  `PROTOCOL.md`. The unmerged `tick-anchor-align` branch rewrites that comment; M2 units are
  forbidden from the file to avoid the conflict. Whoever closes that branch owns the comment.

## Picking this up in a new session

Everything a coordinator needs is in this repo. Nothing lives only in a chat transcript. Read
this file, then `COORDINATION.md`, `PROTOCOL.md`, `NOTES.md`, and `FOLLOW-UPS.md`. Each merged
PR body is that unit's ledger row: verdict, head SHA, and the commands actually run.

**M0 and M1 are both closed, M1j included, and `main` is green.** Tick-anchor alignment, the
client-only fix M1j reported and left out of scope, is the one open unit; M2 is next after it.

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
