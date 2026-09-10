# Verify proof ladder plan

Agents mint a windowed demo per quest today. That does not scale. This program encodes a proof ladder in verify-marque, allowlists demos, instruments NPC DEMO lines, adds a thin WS quest probe, then lands the Consider items (shared PS1 library and NPC arrived). Parent ticket ARM-225. PR order ARM-226, ARM-227, ARM-228, ARM-229, ARM-230, ARM-231, ARM-232.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-stack.md`. The operator lands every PR. Owners stop at merge-ready on the stack.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on her explicit go.
- [ ] On her go, arm a `/goal` with this exact text. "docs/verify-proof-ladder-plan.md. PR order ARM-226, ARM-227, ARM-228, ARM-229, ARM-230, ARM-231, ARM-232. Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Operator lands the stack. Done when every PR box is checked and the stack tip is merge-ready."
- [ ] Read these from trunk at program start. Re-read them at every tick.
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/autopilot-stack.md`
  - [ ] `git show origin/main:pstack/skills/swarm/SKILL.md`
  - [ ] `git show origin/main:.claude/skills/verify-marque/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/opening-a-pr.md`
  - [ ] `git show origin/main:pstack/skills/deslop/SKILL.md`
- [ ] Arm the 30-minute audit tick. In a local session, a real terminal `/loop`. In a remote root, a remote-sleeper wake chain. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read the execution playbook from trunk and the armed /goal. Audit the operation against both and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then send the operator a status message, whether or not anything changed, with the queue table of PR, owner, state, and head SHA, the verdicts since the last tick, what merged, open operator gates, and blockers."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges, or base it on the parent branch when the execution playbook stacks.
  - [ ] ARM-226 and ARM-227 are independent and first. Both branch from `main`. Stack order still places ARM-226 then ARM-227.
  - [ ] ARM-228 after ARM-227 in the stack (no code depend). ARM-229 after ARM-228. ARM-230 after ARM-226. ARM-231 after ARM-227 and ARM-229 and ARM-230. ARM-232 after ARM-229.
- [ ] Hold the file boundaries. ARM-226 touches only `.claude/skills/verify-marque/**`. ARM-227 touches doctor, allowlist, CI, and skill rule lines. ARM-228 touches client NPC scenes and npc_dummy plus tests. ARM-229 touches DEMO helpers and enemy quest demo. ARM-230 touches server net tests and skill cites. ARM-231 touches scripts/*.ps1 library. ARM-232 touches server game NPC arrival and verify-marque GAMELOG vocabulary.
- [ ] Hold the review gate. ARM-228 and ARM-229 change an interaction. They wait for the operator's review in chat with screenshots and a video before merge.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft, with `origin pr create --status open --base <base-branch>` or `gh pr create --base <base-branch>` according to the resolved forge. A stack child targets its parent branch.
- [ ] Run the repo's lint and typecheck once before the PR-facing push. Push with hooks on.
- [ ] Run `/deslop` before each commit and `/no-comments` before review.
- [ ] Triage every Bugbot and security-reviewer comment per `../references/bugbot-triage.md`.
- [ ] Rebase onto current trunk before babysit and again before the merge-ready report.

### Verdict and merge, for every PR

- [ ] At the merge-ready head SHA, run the swarm per `pstack/skills/swarm/SKILL.md`. One gates lane. The ten live lanes from the PR's **Verify, live** block. The perf lane from its **Verify, perf** block. One audit lane that reads the diff and the receipts and distrusts the PR body.
- [ ] Clean only when every lane is `PASS`. Findings go back to the owner. A new head gets a fresh swarm and a fresh verdict.
- [ ] The root appends the PR to the linear base-branch stack on a clean verdict. The operator lands bottom-up. Patch-id rule from `playbooks/shipping.md` applies after rebase.

### Boot recipe, for every live lane

Each live lane runs in its own remote worktree at the PR head. Drive through `control-cli` for doctor, go test, and PowerShell demos. Use verify-marque for windowed Godot when the lane needs pixels.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Start marqued only when the lane needs a live server. Wait for GAMELOG server_started.
- [ ] Deliver input only through verify-marque flags or go test. Read DEMO lines, GAMELOG, doctor stdout, and stderr.
- [ ] Save every screenshot to `/tmp/swarm-<pr-id>/worker-<n>/<slug>.png` and return the paths with the report.

## Encode the proof ladder in verify-marque (ARM-226)

**Depends on.** None.

**Files.**

- [ ] Edit `.claude/skills/verify-marque/SKILL.md`.
- [ ] Edit `.claude/skills/verify-marque/features/README.md`.
- [ ] Edit `.claude/skills/verify-marque/features/enemy-quest-demo.md`.
- [ ] Edit `.claude/skills/verify-marque/features/quest-demo.md`.
- [ ] Edit `.claude/skills/verify-marque/features/two-clients-see-each-other.md`.
- [ ] Edit `.claude/skills/verify-marque/features/contested-pickup.md`.
- [ ] Edit `.claude/skills/verify-marque/features/combat-kill-respawn.md` (retire combat_demo cite).

**Build.**

- [ ] Add Go to headless to thin WS to live demo rung table and the rule that agents pick the lowest falsifying rung.
- [ ] State that verify-marque stays one skill. Do not split client versus server.
- [ ] Label enemy-quest as party and kill-quest outcome proof. Chase and walk-anim are not proven by ENEMY QUEST DEMO OK.
- [ ] Add minimum evidence set tables to the listed feature files.
- [ ] Fix stale COMBAT DEMO OK and combat_demo.ps1 cites.

**You see.**

- [ ] SKILL.md names the four rungs and forbids a new demo per quest id.
- [ ] enemy-quest-demo.md Gotchas say chase is Go or GAMELOG unless a later unit asserts it.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Grep skill and features for rung table and outcome-not-chase wording. Run `rg -n "lowest falsifying rung|outcome-not-chase" .claude/skills/verify-marque`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `sonnet` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run doctor.ps1 at trunk and head. Save `arm-226-lane-1-doctor.png`. Pass when both print DOCTOR OK.
- [ ] Lane 2. Open SKILL.md and screenshot the rung table. Save `arm-226-lane-2-skill-rungs.png`. Pass when four rungs are visible.
- [ ] Lane 3. Open enemy-quest-demo.md Gotchas. Save `arm-226-lane-3-enemy-label.png`. Pass when outcome-not-chase wording is present.
- [ ] Lane 4. Open quest-demo.md evidence table. Save `arm-226-lane-4-evidence-quest.png`. Pass when minimum evidence set table exists.
- [ ] Lane 5. Open enemy-quest-demo.md evidence table. Save `arm-226-lane-5-evidence-enemy.png`. Pass when table separates outcome from chase.
- [ ] Lane 6. Open two-clients-see-each-other.md evidence table. Save `arm-226-lane-6-evidence-walk.png`. Pass when DEMO pos and arrived both listed.
- [ ] Lane 7. Open contested-pickup.md evidence table. Save `arm-226-lane-7-evidence-pickup.png`. Pass when GAMELOG-only core claim is named.
- [ ] Lane 8. Search features for COMBAT DEMO OK. Save `arm-226-lane-8-combat-stale.png`. Pass when no live recipe requires the retired stub.
- [ ] Lane 9. Open features/README.md Driving conventions. Save `arm-226-lane-9-readme-driver.png`. Pass when default driver rung is named.
- [ ] Lane 10. Search SKILL for client versus server skill split advice. Save `arm-226-lane-10-no-split.png`. Pass when text keeps one behavioural skill.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. wall time of doctor.ps1 at trunk and head
- [ ] Probe. Measure doctor.ps1 three times interleaved trunk then head
- [ ] Baseline. Record the trunk median doctor seconds first.
- [ ] Rule. Head median must stay within 1.5x trunk median. Absolute budget 60s.

**Review gate.** None. ARM-226 is not review-gated.


**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR to the base-branch stack. The operator lands the stack bottom-up.

## Allowlist windowed demos (ARM-227)

**Depends on.** None. Ship in stack after ARM-226 so skill text cites the allowlist.

**Files.**

- [ ] Create `.claude/skills/verify-marque/demo-allowlist.txt` (or equivalent manifest).
- [ ] Edit `.claude/skills/verify-marque/doctor.ps1`.
- [ ] Edit CI workflow under `.github/workflows/` if present, else document doctor as the gate.
- [ ] Edit `.claude/skills/verify-marque/SKILL.md` hard rule.

**Build.**

- [ ] Write the allowlist of current `scripts/*demo*.ps1`, `client/scripts/*demo*.gd`, and `--*-shots` flags.
- [ ] Make doctor fail when an unlisted demo file or flag appears.
- [ ] Add skill rule that new quest content must not add a demo file.

**You see.**

- [ ] doctor prints DOCTOR OK on a clean tree.
- [ ] A throwaway unlisted demo file makes doctor fail with a named path.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Run doctor.ps1 on clean tree. Temporarily add `scripts/zz_fake_demo.ps1`, rerun, expect fail, delete the fake.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `sonnet` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. doctor.ps1 at trunk and head. Save `arm-227-lane-1-doctor-ok.png`. Pass when both DOCTOR OK on clean tree.
- [ ] Lane 2. Add unlisted scripts/zz_fake_demo.ps1 and run doctor. Save `arm-227-lane-2-fake-ps1.png`. Pass when doctor fails naming the file.
- [ ] Lane 3. Add unlisted client/scripts/zz_fake_demo.gd and run doctor. Save `arm-227-lane-3-fake-gd.png`. Pass when doctor fails naming the file.
- [ ] Lane 4. Add an unlisted --zz-shots string to the flag scan surface if doctor scans main.gd. Save `arm-227-lane-4-fake-flag.png`. Pass when doctor fails or documents flag allowlist.
- [ ] Lane 5. Confirm quest_demo.ps1 remains allowlisted. Save `arm-227-lane-5-quest-ok.png`. Pass when path is in manifest.
- [ ] Lane 6. Confirm enemy_quest_demo.ps1 remains allowlisted. Save `arm-227-lane-6-enemy-ok.png`. Pass when path is in manifest.
- [ ] Lane 7. Open SKILL.md hard rule section. Save `arm-227-lane-7-skill-rule.png`. Pass when no new demo per quest id is stated.
- [ ] Lane 8. Confirm seed_class_kits_demo.ps1 allowlisted. Save `arm-227-lane-8-seed-kits.png`. Pass when path is in manifest.
- [ ] Lane 9. Decide combat_demo.ps1 stub stay or leave allowlist. Save `arm-227-lane-9-combat-stub.png`. Pass when manifest matches the decision in skill.
- [ ] Lane 10. Remove fakes and rerun doctor. Save `arm-227-lane-10-clean-restore.png`. Pass when DOCTOR OK.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. doctor.ps1 wall time
- [ ] Probe. Interleaved trunk and head doctor runs
- [ ] Baseline. Record the trunk trunk median seconds first.
- [ ] Rule. Head within 2x trunk. Absolute budget 90s including allowlist scan.

**Review gate.** None. ARM-227 is not review-gated.


**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR to the base-branch stack. The operator lands the stack bottom-up.

## Loud fail for missing NPC AnimationPlayer (ARM-228)

**Depends on.** None.

**Files.**

- [ ] Edit `client/scripts/npc_dummy.gd`.
- [ ] Edit `client/scenes/npc_imp.tscn` to author AnimationPlayer when clips allow, or document static policy in the same PR.
- [ ] Edit `client/tests/test_npcs.gd` (or new suite) for the loud path.
- [ ] Edit skill or feature note if Imp walk-anim stays unverified until clips exist.

**Build.**

- [ ] Replace silent return in `_set_walking` when `_animation == null` with `push_error`.
- [ ] Author AnimationPlayer on Imp if required so enemy demos do not false-red, or gate walking calls until configured.
- [ ] Add headless assertion that covers the loud path.

**You see.**

- [ ] Calling `_set_walking(true)` with null AnimationPlayer writes push_error to stderr.
- [ ] Headless suite prints PASS with the new assertion.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Run `godot --headless --path client --script res://tests/run_tests.gd` and confirm the NPC suite holds.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `sonnet` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Headless suite at trunk and head. Save `arm-228-lane-1-headless-pass.png`. Pass when head PASS line present and trunk recorded for baseline.
- [ ] Lane 2. Drive a body with null AnimationPlayer into _set_walking(true). Save `arm-228-lane-2-stderr-null.png`. Pass when stderr contains push_error text.
- [ ] Lane 3. Open npc_imp.tscn after the PR. Save `arm-228-lane-3-imp-scene.png`. Pass when AnimationPlayer exists or static policy is documented in skill.
- [ ] Lane 4. Confirm quest giver still has AnimationPlayer. Save `arm-228-lane-4-quest-giver.png`. Pass when node present.
- [ ] Lane 5. npc_dummy.tscn policy stated. Save `arm-228-lane-5-dummy-capsule.png`. Pass when loud path or AnimationPlayer matches skill.
- [ ] Lane 6. Grep npc_dummy for silent null return in _set_walking. Save `arm-228-lane-6-no-silent.png`. Pass when no quiet return remains.
- [ ] Lane 7. If AnimationPlayer added, dry-run enemy_quest still boots (or note desktop skip). Save `arm-228-lane-7-enemy-smoke.png`. Pass when no new DEMO FAIL from anim alone, or desktop skip recorded.
- [ ] Lane 8. Align client/assets README Imp clip note with the new policy. Save `arm-228-lane-8-assets-readme.png`. Pass when docs match code.
- [ ] Lane 9. Confirm player_avatar still requires AnimationPlayer. Save `arm-228-lane-9-player-contrast.png`. Pass when no silent null path on players.
- [ ] Lane 10. Capture headless PASS marker. Save `arm-228-lane-10-suite-marker.png`. Pass when PASS line on last relevant suite output.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. headless suite wall time
- [ ] Probe. Run run_tests.gd at trunk and head interleaved
- [ ] Baseline. Record the trunk trunk seconds first.
- [ ] Rule. Head within 1.3x trunk. Absolute budget from existing interop norms.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane stderr-null and imp-scene screenshots into media/ARM-228-review-stderr.png and media/ARM-228-review-scene.png.
- [ ] Record a 30 to 60 second video of the headless or editor proof on a lane worktree. Save it as media/ARM-228-review.mp4.
- [ ] Post the screenshots and the video in chat for the operator. Stop at merge-ready. Wait for the operator click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR to the base-branch stack. The operator lands the stack bottom-up.

## DEMO npc and anim capture with mid-chase (ARM-229)

**Depends on.** ARM-228.

**Files.**

- [ ] Create or edit shared capture helper under `client/scripts/` (for example demo_capture.gd).
- [ ] Edit `client/scripts/enemy_quest_demo.gd` (or tab_combat) for mid-chase capture.
- [ ] Edit `scripts/enemy_quest_demo.ps1` asserts for NPC DEMO lines when claiming chase.
- [ ] Edit `.claude/skills/verify-marque/SKILL.md` DEMO grammar.
- [ ] Edit `features/enemy-quest-demo.md` if chase sub-feature becomes verified.

**Build.**

- [ ] Helper dumps every _npcs body as DEMO npc and DEMO anim at capture.
- [ ] Add a mid-chase shot between accept and killsready.
- [ ] Assert walking or displacement when the feature claims chase visibility.

**You see.**

- [ ] Client stdout shows DEMO npc lines with x z and walking flag at the mid-chase shot.
- [ ] DEMO anim prints clip or none.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Grep helper usage and grammar. Prefer a small GDScript unit that calls the helper with a fake session if feasible.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `sonnet` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Diff SKILL DEMO grammar at trunk and head. Save `arm-229-lane-1-grammar.png`. Pass when head lists DEMO npc and DEMO anim.
- [ ] Lane 2. Run enemy_quest_demo.ps1 (desktop) or record skip if no display. Save `arm-229-lane-2-mid-chase.png`. Pass when mid-chase DEMO npc lines exist or skip documented.
- [ ] Lane 3. Read mid-chase client log. Save `arm-229-lane-3-walking-flag.png`. Pass when at least one NPC walking=1 or has_path true during chase.
- [ ] Lane 4. Read DEMO anim lines. Save `arm-229-lane-4-anim-line.png`. Pass when clip or none present for each NPC.
- [ ] Lane 5. Confirm ps1 fails if mid-chase NPC lines missing (sabotage comment-out). Save `arm-229-lane-5-ps1-assert.png`. Pass when named assertion goes red then restored.
- [ ] Lane 6. Shot at accept still works. Save `arm-229-lane-6-accept-shot.png`. Pass when PNG over 4KB.
- [ ] Lane 7. Shot at complete still works. Save `arm-229-lane-7-complete-shot.png`. Pass when ENEMY QUEST DEMO OK if desktop run.
- [ ] Lane 8. Confirm DEMO pos remains avatars-only. Save `arm-229-lane-8-no-avatar-overload.png`. Pass when NPCs use DEMO npc not DEMO pos.
- [ ] Lane 9. Optional reuse helper in tab_combat join dump. Save `arm-229-lane-9-tab-combat.png`. Pass when no regression on DUMMY or TAB markers if touched.
- [ ] Lane 10. enemy-quest feature file matches what the harness proves. Save `arm-229-lane-10-feature-map.png`. Pass when chase verified only if asserted.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. enemy_quest_demo.ps1 wall time when display exists
- [ ] Probe. One interleaved trunk and head run when desktop available, else headless helper microbench
- [ ] Baseline. Record the trunk trunk demo seconds or N/A with absolute budget first.
- [ ] Rule. If desktop, head within 1.3x trunk. Absolute budget 240s. If no display, helper dump under 50ms for 32 NPCs.

**Review gate.** The operator reviews before merge.

- [ ] Copy mid-chase screenshot and log snippet into media/ARM-229-review-midchase.png.
- [ ] Record a 30 to 60 second video of the mid-chase capture. Save it as media/ARM-229-review.mp4.
- [ ] Post the screenshots and the video in chat for the operator. Stop at merge-ready. Wait for the operator click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR to the base-branch stack. The operator lands the stack bottom-up.

## Thin WS quest probe by quest id (ARM-230)

**Depends on.** ARM-226.

**Files.**

- [ ] Create Go test or cmd under `server/internal/net/` using harness_test patterns.
- [ ] Read `shared/quests.json` for ids.
- [ ] Edit verify-marque feature recipes to name the probe as default content rung.

**Build.**

- [ ] Parameterize accept and complete or give flows by quest id.
- [ ] Assert GAMELOG quest_accepted, progress or give, quest_completed.
- [ ] Cover both existing quests without Godot.

**You see.**

- [ ] go test output shows both quest ids green.
- [ ] Feature map points new quests at this probe.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] From server/, run `go test ./internal/net/ -count=1 -run Quest` (exact name from the PR).

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `sonnet` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. go test quest probe at head. Trunk may lack the probe. Save `arm-230-lane-1-go-both.png`. Pass when head runs both quest ids and trunk lack recorded.
- [ ] Lane 2. Probe bring_a_stick accept and complete path. Save `arm-230-lane-2-bring-stick.png`. Pass when GAMELOG quest_completed.
- [ ] Lane 3. Probe slay_imps kill credit path or documented subset. Save `arm-230-lane-3-slay-imps.png`. Pass when quest_kill_progress or complete events.
- [ ] Lane 4. Confirm probe process list has no godot. Save `arm-230-lane-4-no-godot.png`. Pass when only marqued or in-process hub.
- [ ] Lane 5. Probe unknown quest id. Save `arm-230-lane-5-bad-id.png`. Pass when clean failure not panic.
- [ ] Lane 6. Confirm gamelog path used. Save `arm-230-lane-6-gamelog-on.png`. Pass when events present.
- [ ] Lane 7. SKILL or feature names the probe command. Save `arm-230-lane-7-skill-cite.png`. Pass when command string matches.
- [ ] Lane 8. Document whether party credit stays Go unit only. Save `arm-230-lane-8-party-optional.png`. Pass when recipe is explicit.
- [ ] Lane 9. Optional CGO race on the new package if cheap. Save `arm-230-lane-9-race.png`. Pass when pass or skip with reason.
- [ ] Lane 10. Capture go test PASS output. Save `arm-230-lane-10-marker.png`. Pass when ok line for package.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. go test wall time for the new probe cases
- [ ] Probe. Interleaved trunk (skip or empty) and head
- [ ] Baseline. Record the trunk trunk N/A or related net test time first.
- [ ] Rule. Absolute budget 30s for both quests. Fail if head exceeds 30s.

**Review gate.** None. ARM-230 is not review-gated.


**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR to the base-branch stack. The operator lands the stack bottom-up.

## Shared PowerShell demo library (ARM-231)

**Depends on.** ARM-227, ARM-229, and ARM-230.

**Files.**

- [ ] Create `scripts/marque-demo-lib.ps1`.
- [ ] Edit at least `scripts/quest_demo.ps1` and `scripts/enemy_quest_demo.ps1` (or two_client and contested_pickup).

**Build.**

- [ ] Extract evidence dir, GAMELOG parse, client wait, Add-Failure, marker helpers.
- [ ] Migrate two demos. Delete duplicated functions from those scripts.

**You see.**

- [ ] Both demos still print their OK markers last.
- [ ] Library file is the only copy of shared helpers for those demos.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Dot-source the library in a small self-test or run both demo scripts dry for parse errors.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `sonnet` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. quest_demo.ps1 at trunk and head when desktop allows. Save `arm-231-lane-1-quest-ok.png`. Pass when QUEST DEMO OK or skip documented.
- [ ] Lane 2. enemy_quest_demo.ps1 at head when desktop allows. Save `arm-231-lane-2-enemy-ok.png`. Pass when ENEMY QUEST DEMO OK or skip documented.
- [ ] Lane 3. Open marque-demo-lib.ps1. Save `arm-231-lane-3-lib-exists.png`. Pass when shared functions present.
- [ ] Lane 4. Grep Add-Failure in migrated scripts. Save `arm-231-lane-4-no-dup-addfail.png`. Pass when definition only in library.
- [ ] Lane 5. Confirm .marque-evidence still written. Save `arm-231-lane-5-evidence-dir.png`. Pass when marker file exists after run.
- [ ] Lane 6. Broken GAMELOG still fails via library helper. Save `arm-231-lane-6-gamelog-parse.png`. Pass when named failure.
- [ ] Lane 7. doctor still OK. Save `arm-231-lane-7-allowlist.png`. Pass when DOCTOR OK.
- [ ] Lane 8. If two_client migrated, TWO CLIENT DEMO OK. Save `arm-231-lane-8-second-pair.png`. Pass when marker or not-migrated noted.
- [ ] Lane 9. Library docs remind stderr-first on client fail. Save `arm-231-lane-9-stderr-first.png`. Pass when comment or skill cite.
- [ ] Lane 10. Diff line count on migrated scripts. Save `arm-231-lane-10-line-count.png`. Pass when net reduction versus trunk copies.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. quest_demo.ps1 wall time when desktop exists
- [ ] Probe. Interleaved trunk and head
- [ ] Baseline. Record the trunk trunk seconds first.
- [ ] Rule. Head within 1.2x trunk. Absolute 180s.

**Review gate.** None. ARM-231 is not review-gated.


**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR to the base-branch stack. The operator lands the stack bottom-up.

## NPC arrived on GAMELOG (ARM-232)

**Depends on.** ARM-229.

**Files.**

- [ ] Edit `server/internal/game/imp.go` and or `world.go`.
- [ ] Edit `server/internal/game/imp_test.go`.
- [ ] Edit verify-marque skill GAMELOG vocabulary (wire of record stays in code + tests).

**Build.**

- [ ] Log arrived with npc field (or npc_arrived) when an NPC path completes.
- [ ] Unit test covers the event. Sabotage by suppressing the log once and record the red.

**You see.**

- [ ] GAMELOG line with arrived and npc after a chase path in the unit probe.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] From server/, `go test ./internal/game/ -count=1 -run Imp` covering arrived.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `sonnet` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Imp tests at trunk and head. Save `arm-232-lane-1-go-arrived.png`. Pass when head asserts npc arrived and trunk lack recorded.
- [ ] Lane 2. Unit forces aggro chase then path end. Save `arm-232-lane-2-chase-path.png`. Pass when arrived npc event exists.
- [ ] Lane 3. Leash return completion logs arrival or documented skip. Save `arm-232-lane-3-leash-home.png`. Pass when event or explicit skip.
- [ ] Lane 4. Player arrived still uses player field. Save `arm-232-lane-4-player-unchanged.png`. Pass when no regression in move tests.
- [ ] Lane 5. Named Go test asserts `arrived` with `npc` field. Save `arm-232-lane-5-go-arrived.png`. Pass when test names the field.
- [ ] Lane 6. SKILL.md GAMELOG vocabulary updated. Save `arm-232-lane-6-skill-vocab.png`. Pass when event listed.
- [ ] Lane 7. Record sabotage red in feature or test note. Save `arm-232-lane-7-sabotage-red.png`. Pass when red run cited.
- [ ] Lane 8. Confirm wire path broadcast unchanged. Save `arm-232-lane-8-wire-optional.png`. Pass when clients still get path frames.
- [ ] Lane 9. Optional live assert only if ARM-229 chase claims need it. Save `arm-232-lane-9-enemy-optional.png`. Pass when aligned with feature map.
- [ ] Lane 10. go test -race on game package if toolchain ready. Save `arm-232-lane-10-race.png`. Pass when pass or skip with reason.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. imp_test.go wall time
- [ ] Probe. Interleaved trunk and head go test
- [ ] Baseline. Record the trunk trunk seconds first.
- [ ] Rule. Head within 1.5x trunk. Absolute 20s.

**Review gate.** None. ARM-232 is not review-gated.


**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends this PR to the base-branch stack. The operator lands the stack bottom-up.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

No prototype run. Open questions were settled from the prior investigation and code reads. Imp AnimationPlayer policy is decided in ARM-228 (loud push_error plus scene authoring so demos do not false-red). Unproven until execution, desktop availability for enemy_quest mid-chase lanes.

## Appendix B. Alternatives rejected

Split verify-marque into client and server skills. Rejected because two-layer movement proofs need one drive. Full client JSON-mode verify first. Rejected as high build cost for multiplayer. Per-quest windowed demos forever. Rejected as O(N) cost. Scenario DSL before shared DEMO fields and allowlist. Rejected as premature.

## Appendix C. Risks

ARM-228 push_error can red enemy_quest until Imp scene gains AnimationPlayer. Owner watches stderr. ARM-229 mid-chase needs a desktop session. Owner records skip only when display is absent and still ships helper unit proof. ARM-230 party kill credit may stay in game unit tests. Owner must not over-claim wire coverage. ARM-231 migration can drift assertion semantics. Owner keeps markers identical.

## Appendix D. Links and reading list

- Parent https://linear.app/arminas/issue/ARM-225/verify-proof-ladder-scale-tests-without-per-quest-demos
- Children ARM-226 through ARM-232 under that parent
- Atlas feature map template https://github.com/poteto/verification-skill-example/blob/main/.cursor/skills/verify-atlas/references/features/README.md (and `sign-in.md`). ARM-226 follows that four-H2 contract. Evidence and rung live inside Sub-features, Driving, and Gotchas. No fifth H2.
- `.claude/skills/verify-marque/SKILL.md`
- `server/internal/net/harness_test.go`
- how and interrogate on ARM-230 and ARM-232 if wire or event shape debates reopen
- Decision trail per show-me-your-work during autopilot-stack
