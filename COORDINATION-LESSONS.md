# Coordination lessons

Historical war stories and paid-for rules from M0–M2. **Workers do not need this file and it is
never pasted into briefs.** Active gates and recipes live in [COORDINATION.md](COORDINATION.md).

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
