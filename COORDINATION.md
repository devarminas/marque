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

Seven units merged, each with a verdict in its PR body, which is the ledger.

| Unit | PR | Verdicts | What |
|---|---|---|---|
| M1c | #8 | `live-ui-verified`, `conformance-holds-with-findings` | The second registry: ground item bodies, green for a known kind and magenta for an unknown one |
| M1g | #9 | `live-ui-verified` | The demo asserts server state, plus the `verify-marque` skill |
| M1a | #10 | `unit-test-verified`, `conformance-holds-with-findings` | `Store`, ground items, inventory, `pickup`, contested resolution |
| M1h | #11 | `unit-test-verified` | Client stops asserting on a session-wide accumulator, and accepts a `null` list |
| M1b | #12 | `unit-test-verified` | `drop`, pickup's reverse transaction, and a new id every time |
| M1d | #13 | `live-ui-verified` | Clicking an item picks it up; the inventory panel |
| M1e | #14 | `live-ui-verified`, `sabotage-holds-with-findings` | **The milestone.** Two clients, one item, exactly one holder |

**Three units still open, none blocking.** **M1j** hardens the demos: `two_client_demo.ps1` still
passes a teleporting server, `contested_pickup_demo.ps1` asserts no player position so a
teleported loser passes it, its aim check refuses about 29% of runs on a one-tick anchor skew,
and `SKILL.md` carries a false causal claim about the frozen-server sabotage. **M1k** makes the
inventory panel opaque, which is a live product defect proven against a windowed client. **M1f**
implements the slow-client condemnation latch the contract records and nothing yet builds, and
absorbs **M1i**, `hub_test.go`'s background-goroutine `*testing.T` use.

**What M1 cost beyond its plan.** It was cut as five units and ran to ten. Every addition came
from a verifier finding something real, never from the plan growing: a client assertion that
blocked a sibling, a demo that could not tell a frozen server from a live one, a panel that walks
the player, a contract decision nobody had implemented, and a test-only defect found while
reading. **That ratio is the argument for the verification discipline**, not the ceremony around
it. Five verifiers each invented a false pass nobody had listed, and four of the five were real.

Two commands tell you the stack is alive:

- `powershell -ExecutionPolicy Bypass -File scripts/interop_test.ps1` builds the server, binds a
  free port, runs the whole Godot suite against a live `marqued`, and shuts it down. **463
  assertions across 8 suites** as of M1a merging, measured on `main` at `ef5eda8`. This number
  goes stale every time a unit adds a suite, so treat it as "what it was last time somebody
  looked" and report the number you got.
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

**The next false pass in the family is still open, and it is unit M1j.** A *teleporting* server
passes. With `distance := 1000.0` the world crosses a whole path in one tick and emits a
perfectly-formed `arrived`, and the demo prints OK. A 6.204-unit walk at `WalkSpeed` 3.0 on 150ms
ticks takes 14 ticks and every healthy run shows exactly 14, but nothing asserts that the span is
**plausible**. So the demo currently proves the server *finished* the walk, not that it *walked*.
The tell is already printed in the demo's own `==> server:` line.

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
