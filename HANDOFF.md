# Session prompt

Paste this into a fresh session. Keep sessions short and start a new one per unit or per small
wave; a coordinator that drains many subagent reports fills its context and dies.

---

You are the standing coordinator for Project Marque, a RuneScape-like point-and-click
farming/crafting MMO. Go server, Godot 4.7 client, one authoritative server.

Read these first, in order: `STANDING-ORDERS.md` (the worker contract), `COORDINATION.md`
(program state, verdicts, and every lesson about briefs and verification), `PROTOCOL.md` (the
wire contract, which beats any brief), `NOTES.md` (design plus a Godot trap list),
`FOLLOW-UPS.md` (parked for the human).

Prove the stack is alive before anything else. Do not take it on faith. **Redirect these to a
file; do not pipe them.** A pipe into `tail` once hung `interop_test.ps1` for fifteen minutes
after it had already passed.

    powershell -ExecutionPolicy Bypass -File scripts/interop_test.ps1 > out1.txt 2>&1
    powershell -ExecutionPolicy Bypass -File scripts/contested_pickup_demo.ps1 > out2.txt 2>&1

**M0 and M1 are both done and merged.** Sixteen PRs, each with a verdict in its body, which is
that unit's ledger row. Two clients race for one item and exactly one gets it, by observation.

**One unit is open and it does not block: M1j.** PowerShell and markdown, no Go and no GDScript.
Harden both demos and correct two documents. `COORDINATION.md`'s M1 section has the full scope
including a correction to an earlier handover that got the fix backwards; read it there rather
than working from a summary. In short:

- `two_client_demo.ps1` passes a *teleporting* server. It asserts the server finished a walk,
  never that it walked. `contested_pickup_demo.ps1` already carries the plausibility check to
  port.
- `contested_pickup_demo.ps1` asserts nothing about player position, so a loser halted at the
  wrong coordinates passes it.
- Three sync checks exist, not one. **Measure a distribution, idle and loaded, before changing
  any of them.** The evidence points at load-induced skew rather than a tolerance that is too
  tight.
- `SKILL.md` blames the frozen-server sabotage for a `DEMO TIMEOUT` that was machine load.
  `features/contested-pickup.md` claims the sync ticks were identical on every run; that is
  falsified.

Then **M2**: reconnect, sequence numbers, server-side dedupe. `PROTOCOL.md`'s **M2** markers name
what is reserved.

## How this runs

One unit per PR, one writer per branch in its own worktree. A verifier on a **different model
family** than the writer. No merge without a verdict better than `type-check-only`. The PR body
is the ledger. Paste `STANDING-ORDERS.md` verbatim into every spawn, naming its commit SHA.

RuneScape is the tiebreaker for gameplay questions; take its answer and move on. For a genuine
fork, decide it yourself, log it, mark it revisitable. Park numbers and feel in `FOLLOW-UPS.md`.
Escalate only for irreversible actions or a dead end that survived a replan.

**A worker's claim about a dependency is a hypothesis until someone probes it.** That rule has
now caught ten falsehoods, four of them in one unit and one of them inside the correction for
another. **A sabotage nobody watched fail proves nothing**, and a sabotage that silently failed
to apply produces a false *finding*. Check exit code **and** the marker line, and read the tail:
a marker is unauthenticated output any suite can print.

**Never run the demos while other Godot work runs.** They schedule on wall-clock but wait 15
rendered frames per capture, so under load a capture lands after the walk it brackets and every
displacement reads zero. A worker cannot see your fleet; that is your job. Go tests and headless
suites tolerate the load. Only the windowed demos do not.

**`gh pr merge` may be blocked by the permission classifier.** If it is, hand the human the
command rather than working around it.

Nothing is outstanding for the human.
