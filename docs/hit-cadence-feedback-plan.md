# Hit and cadence feedback plan

Combat MVP becomes legible. A white hit shows a damage number, a crit shows a bigger one, a miss shows Miss, an ability shows its cooldown, a refused press says why and costs nothing, and the avatar turns to what it is hitting.

The wire carries hit facts instead of leaving the client to guess from HP deltas. The server enforces the cooldowns its own JSON has declared since ADR 0002 and never checked.

Seven PRs in order, ARM-311, ARM-312, ARM-315, ARM-314, ARM-313, ARM-316, ARM-318. Linear has ARM-317 as a superseded stub and it stays out.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-stack.md`, installed here at `~/.pi/agent/npm/node_modules/@zenspc/pi-pstack/skills/poteto-mode/playbooks/autopilot-stack.md`. One owner per PR builds, self-proves, and opens it ready. The root appends each verified PR to one linear base-branch stack. The operator lands the stack bottom-up. Every PR stops at merge-ready.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [x] State the protocol and this plan to the operator, then stop. Start execution only on her explicit go.
- [x] On her go, record a standing goal with this exact text. "docs/hit-cadence-feedback-plan.md. PR order ARM-311, ARM-312, ARM-315, ARM-314, ARM-313, ARM-316, ARM-318. Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Operator lands the stack. Done when every PR box is checked and the stack tip is merge-ready."
- [x] Read these at program start. Re-read them at every tick.
  - [x] `git show origin/main:.cursor/skills/verify-marque/SKILL.md`
  - [x] `git show origin/main:.cursor/skills/verify-marque/demo-allowlist.txt`
  - [x] Read the four pstack skills from their installed path, since pstack is not vendored in this repo. `~/.pi/agent/npm/node_modules/@zenspc/pi-pstack/skills/poteto-mode/playbooks/autopilot-stack.md`, `~/.pi/agent/npm/node_modules/@zenspc/pi-pstack/skills/swarm/SKILL.md`, `~/.pi/agent/npm/node_modules/@zenspc/pi-pstack/skills/poteto-mode/playbooks/opening-a-pr.md`, and `~/.pi/agent/npm/node_modules/@zenspc/pi-pstack/skills/deslop/SKILL.md`.
- [x] Arm the 30-minute audit tick. In a local session, a real terminal with a recurring wake. Never leave the cadence to memory or to a lossy completion notification.
- [x] Use this tick prompt, verbatim. "Re-read the execution playbook and the standing goal. Audit the operation against both and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then send the operator a status message, whether or not anything changed, with the queue table of PR, owner, state, and head SHA, the verdicts since the last tick, what merged, open operator gates, and blockers."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names, build to first push, ready PR, self-proof, Bugbot triage, deslop, no-comments, babysit.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges, or base it on the parent branch, which this program does.
  - [ ] ARM-311 is first and branches from `main`.
  - [ ] ARM-312 after ARM-311. It needs the swing fields on the wire.
  - [ ] ARM-315 after ARM-312. It needs the miss and crit flags to be honest.
  - [ ] ARM-314 has no code dependency. It stacks after ARM-315 in the one linear chain.
  - [ ] ARM-313 after ARM-314. It renders the remaining cooldown ARM-314 puts on the wire.
  - [ ] ARM-316 after ARM-314. Both touch the same refusal path, and the cooldown reason string is part of the refusal copy.
  - [ ] ARM-318 has no code dependency. It stacks last.
- [ ] Hold the file boundaries. ARM-311 and ARM-314 both touch `server/internal/net/protocol.go`, so they land in stack order and never in parallel. ARM-315 and ARM-318 both touch `client/scripts/session.gd`, so they land in stack order and never in parallel.
- [ ] Hold the review gate. ARM-312, ARM-313, ARM-314, ARM-315, ARM-316, and ARM-318 change an interaction. They wait for the operator's review in chat with screenshots and a video before merge. ARM-311 is wire only and is not review-gated.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`, which is what this repo has. `command -v origin` fails here, so record the fallback to `gh` and use it for create, edit, view, watch, and merge. Never require `gt`.
- [ ] Open the PR ready, never draft, with `gh pr create --base <base-branch>`. A stack child targets its parent branch.
- [ ] Run the repo's gates once before the PR-facing push. From `server/`, `CGO_ENABLED=1 go test -race ./...`. From the repo root, `godot --headless --path client --script res://tests/run_tests.gd`. Push with hooks on.
- [ ] Run `/skill:deslop` before each commit and `/skill:no-comments` before review.
- [ ] Triage every Bugbot and security-reviewer comment per `../references/bugbot-triage.md`.
- [ ] Rebase onto current trunk before babysit and again before the merge-ready report. This repo has no CI workflow tree, so `doctor.ps1` is the gate.

### Verdict and merge, for every PR

- [ ] At the merge-ready head SHA, run the swarm per `pstack/skills/swarm/SKILL.md`. One gates lane, the ten live lanes from the PR's **Verify, live** block, the perf lane from its **Verify, perf** block, and one audit lane that reads the diff and the receipts and distrusts the PR body.
- [ ] Clean only when every lane is `PASS`. Findings go back to the owner. A new head gets a fresh swarm and a fresh verdict.
- [ ] The root appends the PR to the linear base-branch stack on a clean verdict and sets the child base to the parent branch. The operator lands the stack bottom-up. The patch-id rule from `playbooks/shipping.md` applies after every rebase.

### Boot recipe, for every live lane

Each live lane runs in its own git worktree at the PR head. Drive through `.cursor/skills/verify-marque/SKILL.md`, which is the control skill for this repo.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Use the PowerShell that is installed but not on PATH. `PWSH=/home/armin/.local/share/mise/installs/powershell/7.6.6/pwsh`. Run `$PWSH -NoProfile -File .cursor/skills/verify-marque/doctor.ps1` and require `DOCTOR OK` before any other lane step.
- [ ] Keep `DISPLAY=:0`. Windowed Godot needs a real desktop session. Never automate the desktop mouse. The game screenshots itself.
- [ ] Start marqued only when the lane needs a live server, or let the demo script start it. Readiness is the `server_started` GAMELOG line. Never sleep a guessed interval.
- [ ] Deliver input only through verify-marque flags or go test. Read DEMO lines, GAMELOG, doctor stdout, and stderr. Read client stderr first when a client failed.
- [ ] Save every screenshot to `/tmp/swarm-<pr-id>/worker-<n>/<slug>.png` and return the paths with the report.

## Wire hit facts on swing and cast resolve (ARM-311)

**Depends on.** None. Branches from `main`.

**Files.**

- [ ] Edit `server/internal/net/protocol.go`. Add three fields to `Swing` and two to `CastPhase`.
- [ ] Edit `server/internal/game/combat.go`. Change `rollWhiteDamage` to report crit, and pass the applied amount to all three swing emit sites.
- [ ] Edit `server/internal/game/imp.go` at `stepImpAttack` for the NPC to player emit.
- [ ] Edit `server/internal/game/cast.go`. Make the apply helpers return the applied delta and move the resolve broadcast below the application.
- [ ] Edit `server/internal/net/harness_test.go` and `server/internal/net/protocol_test.go` for the new fields.
- [ ] Edit `server/internal/game/presentation_test.go` and `server/internal/game/combat_test.go` for the new assertions.
- [ ] Edit `client/scripts/net_client.gd` and `client/tests/test_presentation_protocol.gd` so the client decodes the fields without branching on them.
- [ ] Edit `docs/adr/0013-actor-presentation-broadcasts.md` to name the new keys.

**Build.**

- [ ] Add to `mnet.Swing` the fields `Amount int` json `amount`, `Crit bool` json `crit`, and `Miss bool` json `miss`. All three are always present, so no reader has to treat absence as a meaning.
- [ ] Add to `mnet.CastPhase` the fields `Amount int` json `amount,omitempty` and `Effect string` json `effect,omitempty`. Only a resolve frame carries them, so a begin and a cancel frame stay byte-identical to today.
- [ ] Replace the `int` return of `rollWhiteDamage` with one small result value that carries the applied damage and the crit flag. Miss is always false in this PR. Model the roll as one value rather than three out-parameters.
- [ ] Change `castTarget.applyHeal` and `castTarget.applyDamage` to return the applied delta after the target clamp, not the pre-clamp number.
- [ ] Move the resolve broadcast in `applyCast` below the application, so `Amount` is the delta the target actually took. Keep the begin and cancel broadcasts where they are.
- [ ] Fill `Amount`, `Crit`, and `Miss` at `resolveAttack`, `resolveAttackOnNPC`, and `stepImpAttack`, one line above each existing `broadcastHP`.
- [ ] Add `crit` and `miss` to the `attack_hit` GAMELOG event so a lane can read the roll without the wire.
- [ ] Decode the new fields in `net_client.gd` `_on_swing` and `_on_cast_phase` and pass them on the existing `swing_observed` and `cast_phase_observed` signals. Touch no client logic.

**You see.**

- [ ] A player swing frame reads `{"swing":{"amount":7,"crit":false,"id":1,"miss":false,"target":2,"weapon":"sword"}}`.
- [ ] A fireball resolve frame reads `{"cast_phase":{"ability":"fireball","amount":22,"effect":"damage","id":1,"phase":"resolve","target":2}}`.
- [ ] A heal resolve near full health reports the clamped delta, not 25.
- [ ] A fireball begin frame is unchanged from trunk.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add a case to `presentation_test.go` asserting the swing frame carries `amount`, `crit`, and `miss` at the player to NPC site.
- [ ] Add a case asserting the NPC to player site in `imp_test.go`.
- [ ] Add a case asserting `applyCast` reports the applied delta for a heal that clamps.
- [ ] Add a case asserting a begin and a cancel frame carry no `amount` and no `effect`.
- [ ] Update the exact JSON table in `protocol_test.go` for both frames.
- [ ] Run `cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestSwing|TestPlayerFireball|TestInstantHeal|TestImpFireball|TestWornBroadcasts'` and `cd server && CGO_ENABLED=1 go test -race ./internal/net/ -run 'TestEncodeProducesKeyAsTagEnvelope|TestDecodeNamesEveryMessageAfterItsWireKey'`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `dummy_attack_demo.ps1` and `cast_bar_demo.ps1` at trunk and at head. Trunk has no `amount` key, so record that and gate the behavior the diff adds instead. Save `arm-311-lane-1-regression.png`. Pass when both demos print their OK marker at head and the trunk frames are recorded as lacking the fields.
- [ ] Lane 2. Player to NPC white hit. Run `dummy_attack_demo.ps1`. Save `arm-311-lane-2-player-npc.png`. Pass when the client stdout shows a swing with a positive amount and `crit=false`.
- [ ] Lane 3. NPC to player white hit. Run `enemy_midchase_demo.ps1` until an Imp lands a white. Save `arm-311-lane-3-npc-player.png`. Pass when the GAMELOG and the wire carry an amount on the Imp swing.
- [ ] Lane 4. Fireball resolve. Run `dummy_cast_demo.ps1`. Save `arm-311-lane-4-fireball.png`. Pass when the resolve frame carries `effect=damage` and an amount equal to the target HP delta.
- [ ] Lane 5. Heal resolve. Run `heal_wounded_demo.ps1`. Save `arm-311-lane-5-heal.png`. Pass when the resolve frame carries `effect=heal` and the amount equals the HP rise.
- [ ] Lane 6. Begin and cancel stay lean. Run `cast_bar_demo.ps1` and read the interrupt. Save `arm-311-lane-6-begin-cancel.png`. Pass when the begin and cancel frames contain no `amount` and no `effect` key.
- [ ] Lane 7. Instant ability with no begin. Run `dummy_cast_demo.ps1` and read the heal. Save `arm-311-lane-7-instant.png`. Pass when a resolve arrives with no preceding begin and still carries amount and effect.
- [ ] Lane 8. Swing still precedes HP. Run `dummy_attack_demo.ps1`. Save `arm-311-lane-8-order.png`. Pass when the swing frame index is below every HP frame for the same target in the run.
- [ ] Lane 9. Wire table. Run the `internal/net` package test. Save `arm-311-lane-9-protocol-table.png`. Pass when the exact JSON table passes for both frames.
- [ ] Lane 10. Client decode without branching. Run `godot --headless --path client --script res://tests/run_tests.gd`. Save `arm-311-lane-10-client.png`. Pass when the suite exits 0 with its PASS line and the presentation protocol suite covers the two new fields.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of `go test ./internal/game -run TestSwing -count=1` and `go test ./internal/net -run TestEncodeProducesKeyAsTagEnvelope -count=1`, plus the `ticks_dropped` count in the demo GAMELOG.
- [ ] Probe. Run both Go commands and `dummy_attack_demo.ps1` at trunk and at head, interleaved trunk, head, trunk, head.
- [ ] Baseline. Record the trunk seconds first. Trunk measured today as game 4.9 s and net 175.4 s for the full packages.
- [ ] Rule. Head `internal/game` within 1.5x trunk and head `internal/net` within 1.5x trunk. Zero `ticks_dropped` at head. Absolute ceiling of 300 s for the full server suite.

**Review gate.** None. ARM-311 is not review-gated. It carries no client-visible change and routes fields without branching on them.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR as the stack root. The operator lands it bottom-up.

## White miss knob and crit honesty (ARM-312)

**Depends on.** ARM-311. The swing frame must carry the crit and miss flags.

**Files.**

- [ ] Edit `server/internal/game/combat.go`. Add the miss roll inside the white roll.
- [ ] Edit `server/internal/game/world.go`. Add the knob field and its setter.
- [ ] Edit `server/cmd/marqued/main.go`. Add the `-white-miss-pct` flag.
- [ ] Edit `server/internal/game/combat_test.go` and `server/internal/game/stats_test.go` for miss, crit, and normal hit.
- [ ] Edit `server/internal/game/presentation_test.go` for the miss flag on the wire.
- [ ] Edit `scripts/dummy_attack_demo.ps1` and `client/scripts/dummy_attack_demo.gd` for the miss mode.
- [ ] Edit `docs/adr/0014-weapon-data-white-damage.md` with the miss rule.

**Build.**

- [ ] Add `whiteMissPct int` to `World` with the zero value meaning miss disabled, plus `SetWhiteMissPct`. Add `DefaultWhiteMissPct = 5` and use it as the `-white-miss-pct` flag default, matching how `-friendly-hp` reaches the world.
- [ ] Roll the miss inside the white roll before damage is rolled. On a miss return zero damage and no crit, and skip both the damage draw and the crit draw so the miss costs exactly one draw.
- [ ] Keep the miss knob off the ability path. `applyCast` never consults it, so spells and heals are unaffected.
- [ ] Emit the miss on the swing frame and in `attack_hit`, with no HP broadcast and no HP debit for that target.
- [ ] Keep the armor floor of 1 on a hit. A miss is not a floored hit and reports `miss=true` with `amount=0`.
- [ ] Add a `-WhiteMissPct` parameter to `dummy_attack_demo.ps1`, default 0, passed to marqued. In the miss mode the client prints a miss line from the swing frame instead of waiting for an HP drop, and the harness asserts the miss, the absent HP debit, and the unchanged dummy HP.

**You see.**

- [ ] With `-white-miss-pct 100`, every white swing frame reads `miss=true`, `crit=false`, `amount=0`, and the target HP never moves.
- [ ] With `-white-miss-pct 0`, whites roll exactly as they do today and consume the same number of RNG draws.
- [ ] With `-white-miss-pct 100`, a healed target still gains HP.
- [ ] With DEX above baseline and the knob at 0, a crit frame reads `crit=true` on the same rolls that crit today.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add a seeded miss case at `whiteMissPct = 100` asserting no HP debit, `miss=true`, and `crit=false`.
- [ ] Add a seeded crit case at `whiteMissPct = 0` with DEX forced, asserting `crit=true` and the doubled pre-armor amount.
- [ ] Add a seeded normal hit case asserting the existing range.
- [ ] Add a case asserting the zero knob consumes the same draw count as trunk, so every existing seeded test keeps its sequence.
- [ ] Add a case asserting a heal at `whiteMissPct = 100` still heals.
- [ ] Run `cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestWhite|TestCast|TestRoll'`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `dummy_attack_demo.ps1` at trunk and head with the default knob. Save `arm-312-lane-1-regression.png`. Pass when both print `DUMMY ATTACK DEMO OK`.
- [ ] Lane 2. Miss at 100 percent. Run `dummy_attack_demo.ps1 -WhiteMissPct 100`. Save `arm-312-lane-2-miss.png`. Pass when `attack_hit` carries `miss=true` and the dummy HP equals its seed.
- [ ] Lane 3. No crit on a miss. Read the same run. Save `arm-312-lane-3-miss-crit.png`. Pass when the miss event carries `crit=false`.
- [ ] Lane 4. Crit honesty. Run the seeded Go crit case and read the event. Save `arm-312-lane-4-crit.png`. Pass when `crit=true` and the amount is the doubled pre-armor value minus armor.
- [ ] Lane 5. Normal hit at the default knob. Run `dummy_attack_demo.ps1` three times with the default 5 percent. Save `arm-312-lane-5-default.png`. Pass when hits land in every run and the miss rate across the runs is at or below 20 percent.
- [ ] Lane 6. The knob at 0 consumes no extra draw. Run the draw count case at trunk and head. Save `arm-312-lane-6-zero.png`. Pass when both counts are equal and every pre-existing seeded test is unchanged.
- [ ] Lane 7. Spells are untouched. Run `dummy_cast_demo.ps1 -WhiteMissPct 100`. Save `arm-312-lane-7-spells.png`. Pass when both the heal and the fireball land.
- [ ] Lane 8. No crit at baseline DEX. Run the seeded case at DEX 10. Save `arm-312-lane-8-nocrit.png`. Pass when `crit=false`.
- [ ] Lane 9. Armor floor holds on a hit. Run the high-armor case. Save `arm-312-lane-9-floor.png`. Pass when the amount is 1 and `miss=false`.
- [ ] Lane 10. Full server suite with the race detector. Run `cd server && CGO_ENABLED=1 go test -race ./...`. Save `arm-312-lane-10-race.png`. Pass when it exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of `go test ./internal/game -run TestWhite -count=1` and the `ticks_dropped` count in the demo GAMELOG.
- [ ] Probe. Run the Go command and `dummy_attack_demo.ps1 -WhiteMissPct 100` at trunk and at head, interleaved trunk, head, trunk, head. Trunk has no miss mode, so the trunk arm runs the default and its wall time is the baseline.
- [ ] Baseline. Record the trunk seconds first.
- [ ] Rule. Head `internal/game` within 1.5x trunk with an absolute ceiling of 20 s. Zero `ticks_dropped` at head. One extra RNG draw per white is inside the budget and the probe must show no tick drop.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2 screenshots into `/tmp/marque-review/arm-312-miss.png`.
- [ ] Record a 30 to 60 second video of the miss mode on a lane run. Save it as `/tmp/marque-review/arm-312-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR above ARM-311. The operator lands the stack bottom-up.

## Client floating combat text for outgoing hits (ARM-315)

**Depends on.** ARM-311 and ARM-312. The float needs honest amount, crit, and miss flags.

**Files.**

- [ ] Create `client/scripts/floating_combat_text.gd` and `client/scenes/floating_combat_text.tscn`.
- [ ] Edit `client/scripts/session.gd`. Route the swing and cast resolve facts into floats for the local player only.
- [ ] Edit `client/scripts/net_client.gd` only if the decoded fact needs one more signal field.
- [ ] Edit `client/scripts/player_avatar.gd` or `client/scripts/npc_dummy.gd` for the anchor point above the target.
- [ ] Edit `scripts/dummy_attack_demo.ps1`, `client/scripts/dummy_attack_demo.gd`, `scripts/dummy_cast_demo.ps1`, and `client/scripts/dummy_cast_demo.gd` with float assertions.
- [ ] Edit `client/scenes/hud.tscn` if the float mounts under the HUD instead of under the actor.
- [ ] Create `client/tests/test_floating_combat_text.gd` and register it in `client/tests/run_tests.gd`.

**Build.**

- [ ] Author one `Label3D` float in `floating_combat_text.tscn` with three exports, `fct_enabled`, `fct_lifetime_msec`, and `fct_scale`, following the `turn_degrees_per_second` knob convention of an export plus an authored scene value.
- [ ] Give the float one entry point, `show_hit(amount, kind, crit)`, where `kind` is a small closed set of white, miss, spell, and heal. Select the style from a table keyed by kind plus crit rather than a chain of conditionals.
- [ ] Route from `session.gd`. On `swing_observed`, float only when the swing id is the local player and the target is an actor in `_npcs` or `_avatars`.
- [ ] On `cast_phase_observed` with phase resolve, float only when the caster id is the local player, and pick spell or heal from the frame effect.
- [ ] Derive every number from the wire fact. Never compute a float from an HP delta, and never float a miss from a missing HP change.
- [ ] Free the float after `fct_lifetime_msec` with a tween that rises and fades. When `fct_enabled` is false, spawn nothing.
- [ ] Print one DEMO line per float from the float's own state, so a lane can assert the text, the style bucket, and the amount without pixels.

**You see.**

- [ ] A white hit prints `DEMO fct white=7`.
- [ ] A crit prints `DEMO fct crit=14` and the label is larger than the white case.
- [ ] A miss prints `DEMO fct miss` and the label reads Miss in grey.
- [ ] A heal prints `DEMO fct heal=+25`.
- [ ] FCT off prints no `DEMO fct` line at all.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add a tree-free case for the style table, one per kind, asserting the literal text, the literal colour, and the size ordering between a white and a crit.
- [ ] Add a scene case that ingests a swing frame through the real `ingest_text_frame` and asserts one float node exists with the expected text.
- [ ] Add a case that ingests a miss frame with no HP frame and asserts a float still appears, which proves the float is not HP derived.
- [ ] Add a case that ingests a swing for another player id and asserts no float.
- [ ] Add a case with `fct_enabled` false asserting no float node.
- [ ] Run `godot --headless --path client --script res://tests/run_tests.gd`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `dummy_attack_demo.ps1` at trunk and head. Save `arm-315-lane-1-regression.png`. Pass when trunk prints no `DEMO fct` line, that fact is recorded, and head still prints `DUMMY ATTACK DEMO OK`.
- [ ] Lane 2. White float. Run `dummy_attack_demo.ps1`. Save `arm-315-lane-2-white.png`. Pass when `DEMO fct white=N` equals the `attack_hit` amount in the GAMELOG.
- [ ] Lane 3. Crit float styling. Run the seeded crit path through `dummy_attack_demo.ps1` with a crit forced. Save `arm-315-lane-3-crit.png`. Pass when the crit float reports a larger scale than the white float in the same run.
- [ ] Lane 4. Miss float. Run `dummy_attack_demo.ps1 -WhiteMissPct 100`. Save `arm-315-lane-4-miss.png`. Pass when the line reads `DEMO fct miss`, the label colour is the grey literal, and no HP frame follows the swing.
- [ ] Lane 5. Spell damage float. Run `dummy_cast_demo.ps1` and read the fireball. Save `arm-315-lane-5-spell.png`. Pass when `DEMO fct spell=N` equals the resolve amount.
- [ ] Lane 6. Heal float. Run `heal_wounded_demo.ps1`. Save `arm-315-lane-6-heal.png`. Pass when the line reads `DEMO fct heal=+N` with the resolve amount.
- [ ] Lane 7. FCT off. Run `dummy_attack_demo.ps1` with `fct_enabled` false. Save `arm-315-lane-7-off.png`. Pass when no `DEMO fct` line appears and the demo still prints its OK marker.
- [ ] Lane 8. Not HP derived. Compare the miss run byte for byte against the white run. Save `arm-315-lane-8-not-hp.png`. Pass when the miss float exists while the target HP frames show no change.
- [ ] Lane 9. Lifetime. Read two samples one lifetime apart in the same run. Save `arm-315-lane-9-lifetime.png`. Pass when the float node is present at the first sample and gone at the second.
- [ ] Lane 10. Outgoing only. Run `enemy_party_demo.ps1`, where hits come from other actors. Save `arm-315-lane-10-outgoing.png`. Pass when no float spawns for a swing the local player did not make.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Headless client suite wall time, the `dummy_attack_demo.ps1` wall time, and the `ticks_dropped` count.
- [ ] Probe. Run the headless suite and `dummy_attack_demo.ps1` at trunk and at head, interleaved trunk, head, trunk, head.
- [ ] Baseline. Record the trunk seconds first. Trunk measured today as 30.4 s for the headless suite after a 39.5 s cache warm-up.
- [ ] Rule. Head headless suite within 1.5x trunk with an absolute ceiling of 90 s. Head demo within 1.5x trunk. Zero `ticks_dropped` at head, since a float spawns on the client and must not touch the server tick.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2, lane 3, and lane 4 screenshots into `/tmp/marque-review/arm-315-float-white.png`, `arm-315-float-crit.png`, and `arm-315-float-miss.png`.
- [ ] Record a 30 to 60 second video showing a white hit, a crit, and a miss float. Save it as `/tmp/marque-review/arm-315-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR above ARM-312. The operator lands the stack bottom-up.

## Enforce ability cooldowns on the server (ARM-314)

**Depends on.** None in code. Stacks above ARM-315 in the linear chain so `protocol.go` keeps one writer at a time.

**Files.**

- [ ] Create `server/internal/game/cooldowns.go` with the cooldown set type.
- [ ] Edit `server/internal/game/world.go`. Give `player` a cooldown set and expose the remaining values for the welcome frame.
- [ ] Edit `server/internal/game/cast.go`. Refuse a press inside the cooldown and start the cooldown on a successful resolve.
- [ ] Edit `server/internal/net/protocol.go`. Add the cooldown reason, the cooldown frame, the welcome list, and the resolve field.
- [ ] Edit `server/internal/game/cast_test.go` and `server/internal/game/presentation_test.go`.
- [ ] Edit `client/scripts/net_client.gd` and `client/scripts/session.gd` to decode the remaining value into a cache, with no timer as truth.
- [ ] Edit `client/tests/test_presentation_protocol.gd`.
- [ ] Edit `docs/adr/0002-sim-tick-and-cast-timing.md`. Strike item 4, which says enforcement is not implemented.

**Build.**

- [ ] Add `type cooldowns struct` to `cooldowns.go` with `ready(ability string, tick int64) bool`, `start(ability string, ticks int, tick int64)`, `remaining(ability string, tick int64) int`, and `snapshot(tick int64) []mnet.Cooldown`. One type owns the whole rule instead of a map poked from several call sites.
- [ ] Add `ReasonCooldown RejectReason = "cooldown"` and refuse a press inside the cooldown through the existing `refuse` path, so the press costs no mana and starts no cast.
- [ ] Start the cooldown in `finishCast` after `applyCast` succeeds, using `abilitydef.Ability.CooldownTicks` for that ability. A cancelled cast starts nothing.
- [ ] Add `type Cooldown struct` with `Ability string` json `ability` and `Remaining int` json `remaining`. Add `Cooldowns []Cooldown` json `cooldowns,omitempty` to `Welcome` so a reconnect mid cooldown resyncs.
- [ ] Add `Cooldown int` json `cooldown,omitempty` to the resolve frame so the client learns the new cooldown the moment it starts.
- [ ] Keep the client cache anchored to the server tick. Store the remaining at the anchor tick, derive the display value from the tick clock, and re-anchor on every resolve and every welcome. A local timer is a cache, never the authority.
- [ ] Add no global cooldown. A first cast is never refused for readiness, and the check is per ability id.

**You see.**

- [ ] A second fireball press inside 75 ticks is refused with reason `cooldown`, mana unchanged, and no begin frame.
- [ ] A second heal press inside 38 ticks is refused the same way.
- [ ] A press after the cooldown begins normally and spends mana at resolve.
- [ ] A reconnect mid cooldown carries `cooldowns` with the remaining ticks on the welcome frame.
- [ ] A fireball resolve frame reads `{"cooldown":75,...}`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add a case for fireball refuse inside the cooldown, asserting the reason, unchanged mana, and zero begin frames.
- [ ] Add a case for heal refuse inside the cooldown.
- [ ] Add a case for success after the cooldown elapses, asserting the mana spend and the begin frame.
- [ ] Add a case that a cancelled cast starts no cooldown.
- [ ] Add a case that a first cast at tick 0 is never refused for cooldown.
- [ ] Add a case that the welcome snapshot carries the remaining ticks after a mid cooldown reconnect.
- [ ] Run `cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestCooldown|TestCastFireball|TestInstantHeal'`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `cast_bar_demo.ps1` at trunk and head. Save `arm-314-lane-1-regression.png`. Pass when trunk prints `CAST BAR DEMO OK`, head prints it after the reject gate is narrowed to the happy path window, and trunk records no cooldown reason.
- [ ] Lane 2. Fireball refuse inside the cooldown. Save `arm-314-lane-2-fireball-cd.png`. Pass when `cast_rejected` carries reason `cooldown` and the player mana equals the value before the press.
- [ ] Lane 3. Heal refuse inside the cooldown. Save `arm-314-lane-3-heal-cd.png`. Pass when the reason is `cooldown` and no begin frame follows.
- [ ] Lane 4. Success after the cooldown. Save `arm-314-lane-4-after-cd.png`. Pass when the later press produces a begin frame and a mana spend.
- [ ] Lane 5. No begin on a refused press. Save `arm-314-lane-5-no-begin.png`. Pass when the refused press is followed by zero `cast_begin` events.
- [ ] Lane 6. Welcome resync. Force a mid cooldown reconnect in the lane run. Save `arm-314-lane-6-welcome.png`. Pass when the welcome frame carries the ability and a remaining value below the catalog total.
- [ ] Lane 7. Resolve carries the new cooldown. Save `arm-314-lane-7-resolve-cd.png`. Pass when the fireball resolve carries 75 and the heal resolve carries 38.
- [ ] Lane 8. Per ability, not global. Save `arm-314-lane-8-per-ability.png`. Pass when heal is refused while fireball is ready in the same run.
- [ ] Lane 9. No global cooldown. Save `arm-314-lane-9-no-gcd.png`. Pass when a first cast at the start of the run is never refused for readiness.
- [ ] Lane 10. Full server suite with the race detector. Save `arm-314-lane-10-race.png`. Pass when it exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of `go test ./internal/game -run TestCooldown -count=1`, the `cast_bar_demo.ps1` wall time, and the `ticks_dropped` count.
- [ ] Probe. Run both at trunk and at head, interleaved trunk, head, trunk, head. Trunk lacks the feature, so its arm measures the same demo and the same package without the cooldown tests.
- [ ] Baseline. Record the trunk seconds first.
- [ ] Rule. Head `internal/game` within 1.5x trunk with an absolute ceiling of 20 s. Head demo within 1.5x trunk. Zero `ticks_dropped`, since the cooldown check is one map lookup per press and the snapshot runs only on join.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2 and lane 4 screenshots into `/tmp/marque-review/arm-314-cd-refuse.png` and `arm-314-after-cd.png`.
- [ ] Record a 30 to 60 second video of a refused early press and a later successful one. Save it as `/tmp/marque-review/arm-314-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR above ARM-315. The operator lands the stack bottom-up.

## Hotbar cooldown chrome from server remaining (ARM-313)

**Depends on.** ARM-314. The remaining value must be on the wire before any slot can draw it.

**Files.**

- [ ] Edit `client/scripts/hotbar.gd`. Hold the per ability remaining cache and repaint on tick.
- [ ] Edit `client/scripts/hotbar_slot.gd`. Add the sweep state and the ready state.
- [ ] Edit `client/scenes/hotbar_slot.tscn` and `client/scenes/hud.tscn` for the overlay node and its authored values.
- [ ] Edit `client/scripts/session.gd`. Expose the cooldown cache and signal its changes, and clear it on both teardown paths.
- [ ] Edit `client/tests/test_hotbar.gd` and add the sweep cases.
- [ ] Edit `client/scripts/cast_bar_demo.gd` to press a hotbar slot instead of calling `request_cast` directly.

**Build.**

- [ ] Add a `Cooling` overlay `ColorRect` to `hotbar_slot.tscn` and a `show_cooldown(remaining, total)` entry beside `show_ability` and `show_empty`. The overlay height fraction is `remaining / total`, and `total` comes from the local catalog `cooldown_ticks` for that ability.
- [ ] Keep one slot state machine with three states, ready, cooling, and empty, instead of independent boolean flags.
- [ ] In `hotbar.gd`, keep a cache of ability to the anchor tick and remaining ticks, and recompute the display value each frame from the server tick. Re-anchor on every resolve and on welcome.
- [ ] Add `cooldowns_changed` in `session.gd` and clear the cache in `_on_welcomed` and `_on_disconnected`, so a reconnect never leaves a stuck sweep.
- [ ] Draw the remaining seconds as a short number in the slot, and leave a ready slot looking exactly as it does today.
- [ ] Press a slot in `cast_bar_demo.gd` through `HotbarScript.ability_activated` so the demo exercises the real press path and not a direct session call.

**You see.**

- [ ] After a fireball resolve, the fireball slot shows a dark overlay draining from full to empty over 75 ticks.
- [ ] The heal slot stays idle while fireball cools.
- [ ] The overlay is gone at the end of the cooldown and the slot looks ready.
- [ ] A reconnect mid cooldown restores the sweep at the remaining value from the welcome frame.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add a headless case that feeds a remaining value and asserts the overlay fraction within 0.1 of `remaining / total`.
- [ ] Add a case that a zero remaining hides the overlay and leaves the slot enabled.
- [ ] Add a case that a new resolve re-anchors a deliberately wrong local value.
- [ ] Add a case that welcome restores a mid cooldown state after a teardown.
- [ ] Keep the source check that the hotbar authoring stays in the scene and never calls `add_child`.
- [ ] Run `godot --headless --path client --script res://tests/run_tests.gd`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `cast_bar_demo.ps1` at trunk and head. Save `arm-313-lane-1-regression.png`. Pass when trunk prints `CAST BAR DEMO OK` with no sweep line and head prints it with the sweep, and the trunk gap is recorded.
- [ ] Lane 2. Sweep appears. Save `arm-313-lane-2-sweep.png`. Pass when the fireball slot reports a visible overlay and a remaining above zero right after the resolve.
- [ ] Lane 3. Sweep drains. Save `arm-313-lane-3-drain.png`. Pass when the second sample reports a lower remaining than the first.
- [ ] Lane 4. Ready slot is idle. Save `arm-313-lane-4-ready.png`. Pass when the heal slot reports no overlay while fireball cools.
- [ ] Lane 5. Reconnect resync. Save `arm-313-lane-5-resync.png`. Pass when the sweep after the reconnect matches the welcome remaining within 2 ticks.
- [ ] Lane 6. Re-anchor. Save `arm-313-lane-6-reanchor.png`. Pass when a second cast corrects a sweep that was deliberately offset in the run.
- [ ] Lane 7. Per slot isolation. Save `arm-313-lane-7-per-slot.png`. Pass when the heal slot stays ready while the fireball slot sweeps.
- [ ] Lane 8. Fraction correctness. Save `arm-313-lane-8-fraction.png`. Pass when the reported overlay fraction is within 0.1 of remaining over the catalog total.
- [ ] Lane 9. Sweep clears at zero. Save `arm-313-lane-9-clear.png`. Pass when a sample after the cooldown reports no overlay.
- [ ] Lane 10. Headless suite. Run `godot --headless --path client --script res://tests/run_tests.gd`. Save `arm-313-lane-10-headless.png`. Pass when it exits 0 and the last line is the PASS line.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Headless client suite wall time, the `cast_bar_demo.ps1` wall time, and the `ticks_dropped` count.
- [ ] Probe. Run both at trunk and at head, interleaved trunk, head, trunk, head.
- [ ] Baseline. Record the trunk seconds first. Trunk measured today as 30.4 s for the headless suite.
- [ ] Rule. Head suite within 1.5x trunk with an absolute ceiling of 90 s. Head demo within 1.5x trunk. Zero `ticks_dropped`, since the sweep is client side per frame work on one node.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2 and lane 3 screenshots into `/tmp/marque-review/arm-313-sweep.png` and `arm-313-drain.png`.
- [ ] Record a 30 to 60 second video of a cast and its draining slot. Save it as `/tmp/marque-review/arm-313-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR above ARM-314. The operator lands the stack bottom-up.

## Refusal strings and no debit on a refused press (ARM-316)

**Depends on.** ARM-314. The cooldown refusal is one of the three strings this unit shows.

**Files.**

- [ ] Edit `server/internal/net/protocol.go`. Put the reject reason on the error frame.
- [ ] Edit `server/internal/game/world.go` in `refuse` and `rejectionEvent`, so the reason reaches the wire and not only the log.
- [ ] Edit `server/cmd/marqued/main.go`. Add the `-start-mana` flag.
- [ ] Edit `server/internal/game/cast.go` only if a refusal path is missing a reason.
- [ ] Edit `server/internal/game/cast_test.go` and add `server/internal/game/rejection_event_test.go` coverage for the cast intent.
- [ ] Edit `client/scripts/session.gd`. Key the refusal copy by reason.
- [ ] Edit `client/scripts/error_hud.gd` and `client/scenes/hud.tscn` for the per reason tint and the authored linger.
- [ ] Edit `client/tests/test_error_hud.gd`.
- [ ] Edit `scripts/cast_bar_demo.ps1` and `client/scripts/cast_bar_demo.gd` for the refusal phase.

**Build.**

- [ ] Add `Reason RejectReason` json `reason,omitempty` to `mnet.Error`, filled from the same value `refuse` already logs. The client must never have to match on the human text.
- [ ] Add `startMana int` to `World` with `SetStartMana`, and the `-start-mana` flag on marqued, mirroring `-friendly-hp`. It exists so an out of mana lane is deterministic instead of racing mana regen.
- [ ] Add the three cast entries to `REFUSAL_TEXT` in `session.gd`, keyed by reason, for `insufficient_mana`, `out_of_range`, and `cooldown`. Keep the existing re and detail map for gather and use.
- [ ] Add a per reason tint on the error HUD and one authored linger duration, following the export plus scene value convention. The OOM text and the OOR text must be different strings and different colours.
- [ ] Guarantee no debit. A refused press returns before any begin, and mana is spent only in `applyCast`. Do not add a pre-charge that a refusal has to refund.
- [ ] Narrow the `cast_rejected == 0` gate in `cast_bar_demo.ps1` to the happy path window, and add a refusal phase that presses out of range, then out of mana at `-start-mana 0`, and asserts the reason, the unchanged mana, and the absent begin.
- [ ] Print `DEMO errortext` and `DEMO errorcleared` from the error HUD's own text, following `gather_error_demo.gd`.

**You see.**

- [ ] A refused fireball press shows Out of range, the mana is identical before and after, and no begin frame follows.
- [ ] A refused press at `-start-mana 0` shows Not enough mana in a different colour.
- [ ] A refused press inside a cooldown shows Not ready yet.
- [ ] The text clears after the authored linger.
- [ ] The error frame reads `{"error":{"msg":"out of range","re":"cast","reason":"out_of_range"}}`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add a case that an out of range cast refusal leaves mana unchanged and logs `cast_rejected` with `out_of_range`.
- [ ] Add a case that an insufficient mana refusal leaves mana unchanged and logs `insufficient_mana`.
- [ ] Add a case that neither refusal emits a `cast_begin`.
- [ ] Add a case that the error frame carries the reason for all three cast refusals.
- [ ] Add `mnet.Cast` to the hand written enumeration in `rejection_event_test.go`, which currently omits it.
- [ ] Add a client case mapping each reason to its literal copy and asserting the two mana and range strings differ.
- [ ] Run `cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestCastRefus|TestRejection|TestCooldown'` and `godot --headless --path client --script res://tests/run_tests.gd`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `cast_bar_demo.ps1` at trunk and head. Save `arm-316-lane-1-regression.png`. Pass when both print `CAST BAR DEMO OK` and trunk records no reason key.
- [ ] Lane 2. Out of range string. Run the refusal phase. Save `arm-316-lane-2-oor.png`. Pass when `DEMO errortext` reads the out of range copy.
- [ ] Lane 3. Out of mana string. Run the phase at `-start-mana 0`. Save `arm-316-lane-3-oom.png`. Pass when the copy reads the not enough mana text.
- [ ] Lane 4. No debit. Read the GAMELOG mana for that player across the press. Save `arm-316-lane-4-no-debit.png`. Pass when the mana is identical before and after.
- [ ] Lane 5. No begin. Save `arm-316-lane-5-no-begin.png`. Pass when zero `cast_begin` events follow the refused press.
- [ ] Lane 6. Distinct strings. Save `arm-316-lane-6-distinct.png`. Pass when the OOM text and the OOR text are not equal.
- [ ] Lane 7. Distinct tint. Save `arm-316-lane-7-tint.png`. Pass when the label colour differs between the OOM run and the OOR run.
- [ ] Lane 8. Linger clears. Save `arm-316-lane-8-linger.png`. Pass when the text is present at the authored linger and empty after it, with `DEMO errorcleared`.
- [ ] Lane 9. Reason on the wire. Read the client's decoded frame. Save `arm-316-lane-9-reason.png`. Pass when the client maps by reason and the raw msg text was never compared.
- [ ] Lane 10. Full server suite with the race detector. Save `arm-316-lane-10-race.png`. Pass when it exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of `go test ./internal/game -run TestCastRefus -count=1`, the `cast_bar_demo.ps1` wall time, and the `ticks_dropped` count.
- [ ] Probe. Run both at trunk and at head, interleaved trunk, head, trunk, head. The trunk arm runs the demo without the refusal phase.
- [ ] Baseline. Record the trunk seconds first.
- [ ] Rule. Head `internal/game` within 1.5x trunk with an absolute ceiling of 20 s. Head demo within 1.5x trunk. Zero `ticks_dropped`.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2, lane 3, and lane 7 screenshots into `/tmp/marque-review/arm-316-oor.png`, `arm-316-oom.png`, and `arm-316-tint.png`.
- [ ] Record a 30 to 60 second video of the two refusals and the linger clearing. Save it as `/tmp/marque-review/arm-316-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR above ARM-313. The operator lands the stack bottom-up.

## Soft face-target yaw on attack and cast start (ARM-318)

**Depends on.** None in code. Stacks above ARM-316 so `session.gd` keeps one writer at a time.

**Files.**

- [ ] Create `client/scripts/facing.gd` with the shared yaw helper.
- [ ] Edit `client/scripts/player_avatar.gd`. Add the target facing path and its own rate.
- [ ] Edit `client/scenes/player_avatar.tscn` for the authored rate and the target facing flag.
- [ ] Edit `client/scripts/npc_dummy.gd` to use the shared helper instead of its copy.
- [ ] Edit `client/scripts/session.gd`. Start the turn on the local attack and cast starts, and clear it when the action settles.
- [ ] Edit `client/tests/test_avatar.gd` and `client/tests/test_npcs.gd`.
- [ ] Edit `scripts/dummy_attack_demo.ps1`, `client/scripts/dummy_attack_demo.gd`, `scripts/cast_bar_demo.ps1`, and `client/scripts/cast_bar_demo.gd` for the yaw samples.
- [ ] Edit `docs/adr/0005-ability-locomotion.md` only if the turn rule needs a line.

**Build.**

- [ ] Extract `_yaw_facing` and the rate limited turn from `player_avatar.gd` and its byte identical copy in `npc_dummy.gd` into `client/scripts/facing.gd`, and port both consumers in this PR instead of leaving the third copy behind.
- [ ] Add `face_target_degrees_per_second` to `player_avatar.gd` with its value authored in `player_avatar.tscn`, separate from the travel rate so the two can be tuned apart.
- [ ] Add one facing mode to the avatar, travel, target, or held. While walking, travel wins. While attacking or casting and not walking, target wins. With `face_travel_direction` false the body stays frozen.
- [ ] Add `face_target(pos)` and `clear_face_target()` on the avatar and call them from `session.gd` on the local `attack_requested` and `cast_requested` signals, aimed at the current target's display position.
- [ ] Write the target facing after the `present_at` call in `_advance_locomotion`, so last writer wins is explicit and the turn is not overwritten by the travel heading in the same frame.
- [ ] Clear the target facing when the walk wish resumes, when the target despawns, and on death, so the halt case still holds the last heading.
- [ ] Add no facing gate. Combat resolves exactly as it does today, and a swing from a player facing away still lands.
- [ ] Print the local yaw before the press, mid turn, and after it, so a lane can prove the turn was gradual.

**You see.**

- [ ] Right clicking a hostile while facing away turns the avatar toward it over several frames, not in one frame.
- [ ] Pressing fireball while facing away turns the avatar the same way.
- [ ] Walking resumes and the heading follows the wish again.
- [ ] With `face_travel_direction` false the body never turns.
- [ ] An attack from a facing away player still lands and still costs nothing extra.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add a case that a target facing turns the avatar toward a literal expected yaw.
- [ ] Add a case that samples mid turn and asserts the yaw sits between the start and the target, which proves the rate limit rather than a snap.
- [ ] Add a case that travel wins while walking.
- [ ] Add a case that `face_travel_direction` false leaves the yaw unchanged.
- [ ] Keep the existing halt case asserting the avatar holds its last heading.
- [ ] Add a case that the shared helper serves both the avatar and the npc dummy.
- [ ] Run `godot --headless --path client --script res://tests/run_tests.gd`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `dummy_attack_demo.ps1` and `wasd_demo.ps1` at trunk and head. Save `arm-318-lane-1-regression.png`. Pass when both demos pass at both and the trunk run records no target turn, which is the gap the diff closes.
- [ ] Lane 2. Attack start turns the avatar. Save `arm-318-lane-2-attack-turn.png`. Pass when the yaw after the right click is closer to the target heading than the yaw before it.
- [ ] Lane 3. The turn is rate limited. Save `arm-318-lane-3-rate.png`. Pass when the mid turn sample sits strictly between the start yaw and the target yaw.
- [ ] Lane 4. Cast start turns the avatar. Save `arm-318-lane-4-cast-turn.png`. Pass when a fireball press from a facing away player moves the yaw toward the target.
- [ ] Lane 5. Travel still wins. Run `wasd_demo.ps1`. Save `arm-318-lane-5-travel.png`. Pass when the heading follows the wish direction and the recorded displacement still passes the demo's own wish assert.
- [ ] Lane 6. Facing off freezes the body. Run with `face_travel_direction` false. Save `arm-318-lane-6-facing-off.png`. Pass when the reported yaw before and after the press is identical.
- [ ] Lane 7. Halt still holds. Save `arm-318-lane-7-halt.png`. Pass when the avatar stops and keeps its last heading, matching the existing avatar suite.
- [ ] Lane 8. No facing gate. Save `arm-318-lane-8-no-gate.png`. Pass when the attack lands with the same `attack_hit` and the same damage range as trunk.
- [ ] Lane 9. Shared helper. Save `arm-318-lane-9-helper.png`. Pass when `npc_dummy.gd` calls the extracted helper, its suite is green, and no duplicated yaw function remains.
- [ ] Lane 10. Headless suite. Save `arm-318-lane-10-headless.png`. Pass when the suite exits 0 and the last line is the PASS line.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Headless client suite wall time, the `dummy_attack_demo.ps1` and `wasd_demo.ps1` wall times, and the `ticks_dropped` count.
- [ ] Probe. Run all three at trunk and at head, interleaved trunk, head, trunk, head.
- [ ] Baseline. Record the trunk seconds first. Trunk measured today as 30.4 s for the headless suite and 13.3 s for `wasd_demo.ps1`.
- [ ] Rule. Head suite within 1.5x trunk with an absolute ceiling of 90 s. Head demos within 1.5x trunk. Zero `ticks_dropped`, since the turn is client presentation with no wire change.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2, lane 3, and lane 4 screenshots into `/tmp/marque-review/arm-318-turn.png`, `arm-318-rate.png`, and `arm-318-cast-turn.png`.
- [ ] Record a 30 to 60 second video of an attack and a cast from a facing away player. Save it as `/tmp/marque-review/arm-318-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR as the stack tip. The operator lands the stack bottom-up.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names. The stack root and tip links, a one line verdict per link, the queue table of PR, owner, state, and head SHA, the trail path, and anything parked or excluded with the reason.
- [ ] Confirm every landed PR has a verdict for its current head SHA, and that a rewritten SHA was re-verified.
- [ ] Audit the decision trail against the run before handing back, including the cross-model review the trail skill requires.

## Appendix A. Prototype evidence

Two empirical checks were run at `main` SHA d918c76 before this plan was written. No design fork needed a prototype.

- Harness venue, run on this machine. `pwsh 7.6.6` is installed by mise at `/home/armin/.local/share/mise/installs/powershell/7.6.6/pwsh` and is not on `PATH`. `doctor.ps1` printed `DOCTOR OK` with `go1.27.1` and `godot 4.7.2`. `scripts/wasd_demo.ps1` then printed `WASD DEMO OK` with exit 0 in 13.3 s against `DISPLAY=:0`, evidence at `/tmp/marque-wasd`. Conclusion, the live lanes run locally with the mise PowerShell, so no cloud venue is needed and the boot recipe names that path.
- Trunk baselines. `cd server && CGO_ENABLED=1 go test -race ./...` exited 0 in 3 min 10 s, with `internal/game` at 4.937 s and `internal/net` at 175.441 s. `godot --headless --path client --script res://tests/run_tests.gd` exited 0 in 30.4 s after a 39.5 s cache warm-up and its last line read `PASS: 3202 assertion(s) held across 64 suite(s)`. These are the trunk numbers every perf block compares against.
- Unproven until execution. `-start-mana` and `-white-miss-pct` do not exist yet, so their plumbing is a design read and not a measurement. The miss mode of `dummy_attack_demo` does not exist yet, so the claim that it tolerates a non dropping dummy HP is unproven. The FCT style assertion is claimed as a headless property read, not as pixels, because no demo on this host asserts a pixel and the frame comparison helper returns null off Windows.

## Appendix B. Alternatives rejected

- A per weapon miss chance in `shared/weapons.json`. Rejected. The milestone names one global knob at 5 percent, and a per weapon field would put the number in seven places.
- A World zero value of 5 for `whiteMissPct`. Rejected. The zero value is 0, miss disabled, and only the marqued flag default is 5. A 5 in the zero value would add one RNG draw to every existing seeded test and change the sequence those tests observe.
- Starting the cooldown when the cast begins rather than when it resolves. Rejected. The acceptance criterion says after a successful cast, and a cancelled cast must start nothing.
- A dedicated cooldown message broadcast on start and on expiry. Rejected. The resolve frame plus the welcome snapshot carries the same fact with no new frame and no per tick traffic.
- Cooldown remaining derived from a client timer. Rejected by the milestone and by the client doctrine. The client caches the server remaining and never authors it.
- Floating combat text from HP deltas. Rejected. The milestone forbids it, and practice dummies clamp HP so the delta is not the hit.
- A named pixel contract for the float. Rejected. `Compare-Frames` in `two_client_demo.ps1` returns null unless the host is Windows, so no pixel contract can run here. The float is proven by DEMO lines and a headless property suite.
- A new windowed demo or a new `--fct-shots` flag. Rejected. The verification skill forbids a new demo per feature, and a DEMO line inside an existing allowlisted demo needs no allowlist edit.
- A second rate knob for travel. Rejected. The travel rate stays as it is and the target turn gets its own export, so a tuned travel feel is not disturbed.
- Putting the yaw rate in `keybinds.gd` or `user://`. Rejected. There is no general settings file, and a rate is not a key.
- Hard facing refuse. Out of this milestone. It is ARM-323 in the next milestone and it needs the soft turn to exist first.

## Appendix C. Risks

- PowerShell is not on `PATH`. Every lane uses the mise path from the boot recipe, and a lane that runs `powershell` or `pwsh` bare will fail for the wrong reason.
- Three claims want to land in `cast_bar_demo`, which already carries the walk interrupt claim and a hard `cast_rejected == 0` gate. ARM-314 narrows that gate to the happy path window and ARM-316 adds a refusal phase after it. ARM-314 owns the narrowing, and ARM-316 must not widen it back.
- The `internal/net` suite takes about 175 s at trunk. Lanes that run the full server suite need a wall clock budget above that, and a timeout below it will read as a failure.
- Reordering the resolve broadcast after the application can reorder frames the presentation suite watches. ARM-311 owns the check and must re-run the cast presentation cases.
- ARM-312's miss mode is the only live proof of a miss. If the harness asserts only the miss it could pass while the hit path is broken, so the same run also asserts a landed hit at the default knob.
- `-start-mana` is new server surface. It stays out of the wire and out of the catalogs, reached only by the flag and the world setter, so a player cannot set it.
- The face turn writes yaw from `Session` after `present_at`. ARM-318 owns the last writer wins rule and must keep the walk case winning.
- ARM-311's regression lane has no trunk behavior to compare against for the new fields. The lane records that gap rather than inventing a trunk result, and it gates the added behavior plus the end state the operator waits for.

## Appendix D. Links and reading list

- Milestone https://linear.app/arminas/project/project-marque-525be456de70 with units ARM-311, ARM-312, ARM-313, ARM-314, ARM-315, ARM-316, and ARM-318. ARM-317 is a superseded stub and stays out.
- ARM-311 https://linear.app/arminas/issue/ARM-311/wire-swingcast-phase-hit-facts-damage-crit-miss-amount
- ARM-312 https://linear.app/arminas/issue/ARM-312/white-miss-knob-white_miss_pct-crit-flag-tests
- ARM-314 https://linear.app/arminas/issue/ARM-314/enforce-abilitiesjson-cooldown_ticks-on-server
- ARM-315 https://linear.app/arminas/issue/ARM-315/client-fct-outgoing-whitecritspellhealmiss
- ARM-313 https://linear.app/arminas/issue/ARM-313/hotbar-cd-chrome-from-server-remaining
- ARM-316 https://linear.app/arminas/issue/ARM-316/oomoor-refuse-strings-no-debit-on-press
- ARM-318 https://linear.app/arminas/issue/ARM-318/soft-face-target-yaw-on-attackcast-start
- ADR 0002, `docs/adr/0002-sim-tick-and-cast-timing.md`, which item 4 this program amends.
- ADR 0005, `docs/adr/0005-ability-locomotion.md`, for the locomotion policy the turn must not break.
- ADR 0013, `docs/adr/0013-actor-presentation-broadcasts.md`, for the one end rule and the presentation only rule.
- ADR 0014, `docs/adr/0014-weapon-data-white-damage.md`, for the white formula the miss knob extends.
- ADR 0016, `docs/adr/0016-primary-stats-derived-combat.md`, for crit and armor.
- `.cursor/skills/verify-marque/SKILL.md` and `.cursor/skills/verify-marque/demo-allowlist.txt`.
- Decision trail per `pstack/skills/show-me-your-work/SKILL.md`, one `decisions.tsv` per owner, returned in the report.
- `pstack/skills/how/SKILL.md` for ARM-314 on the cast and cooldown path, and `pstack/skills/interrogate/SKILL.md` if the wire shape for cooldown is contested at review.
