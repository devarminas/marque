# Marque verification map

Behavior-level inventory of Project Marque. Agents use this map to pick a recipe and
the lowest falsifying rung. Humans use it as the regression checklist. Launch,
doctor, drive, evidence, and cleanup live in [../SKILL.md](../SKILL.md).

## Baseline preconditions

- `doctor.ps1` reports `DOCTOR OK`.
- On a fresh checkout, warm Godot caches once:
  `godot --headless --path client --editor --quit` (`run.ps1` self-heals this).
- Windowed clients need a real desktop session; headless renders nothing.
- Servers bind `127.0.0.1:0` and announce the port in `server_started`. Never assume
  a fixed port.
- Every run owns its processes and stops them by PID.

## Driving conventions

- Default driver rung is the **lowest falsifying rung** that can kill the claim
  (Go → headless → thin WS → live demo). See *Proof ladder* in `../SKILL.md`.
  Feature `Driving` sections name the preferred rung when it is not obvious.
- Screenshot prefixes are absolute host paths; two clients share one `user://`.
- Resolve player ids from each client's `DEMO joined` line, never from launch
  order. The clients race to connect.
- A run passed only if it exited 0 **and** its marker line printed
  (`VERIFY HARNESS OK`, `TWO CLIENT DEMO OK`, `INTEROP OK`, `PASS:`). Neither
  alone proves anything. Take the marker from the last line, not from a grep.
- Treat every command as literal; keep flags and quoting unchanged.
- Do not remove proof artifacts during cleanup. The harness that wrote them
  empties its own output directory at the start of its *next* run.

## Reviewer evidence (human-facing, not a pass)

When the PR changes something a human should see without launching the client,
attach 1–3 screenshots or a short clip after the DEMO+GAMELOG (or Go / headless)
verify run. See *Reviewer-facing evidence* in `../SKILL.md`. PNG/video presence
is never a behavioural pass (ARM-289). Kind:

| Kind | Use when | Skip when |
|---|---|---|
| screenshot | chrome/layout at rest (hover popup content, sheet open, badge, ring) | the claim is wire/store only |
| video / frames | timing or motion (hover pop-in/out, Use-mode on→off, sheet dismiss) | one still frame already shows the state |
| none | heartbeat, rejected intents, `move_to` refuse, contested store races | — |

Visual features (put a one-line **Reviewer evidence:** note in Driving or Gotchas;
do not add a fifth H2):

- [Two clients see each other walk](./two-clients-see-each-other.md) — screenshot
  (or existing demo PNGs); named-pixel still-camera stays the pixel *proof*.
- [Tab targeting](./tab-targeting.md) — screenshot of the yellow ring at rest;
  Escape-clear is frames if timing is the claim.
- [Equip the join-kit weapon](./equip-weapon.md) — screenshot of the right dock.
- [Mine, smelt, craft sword](./craft-cast-demo.md) — screenshot of bag/recipe at
  rest; cast-bar appear/interrupt is video.
- [Gather then craft](./gather-craft.md) — future Use-mode / hover / recipe-sheet
  PRs: video for enter→highlight→cancel and hover pop; screenshot for a sheet
  at rest. Drive existing demos or `--screenshot` / `--record-frames`.
- [Cast effect on target](./cast-effect-on-target.md) — flash is temporal (clip
  or pre/post frames).
- [Prop: player character](./polish/props/player-character.md) — screenshot at
  rest; walk/jump timing is frames.

Capture + attach: `review-evidence.sh` (Linux) or `review-evidence.ps1`
(Windows). Preferred GitHub surface: `gh pr comment --attach`. Fill the
**Reviewer evidence** section of `.github/PULL_REQUEST_TEMPLATE.md`.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- **Default proof is DEMO + GAMELOG.** Assert both layers when the claim spans them:
  what the client reported (`DEMO` lines) and what the server believes (GAMELOG).
  Name the minimum set inside Sub-features, Driving, or Gotchas. Do not invent a
  fifth H2.
- **PNG is named-pixel only.** A screenshot assertion must name the pixel fact that
  would be missing if the claim were false. File existence or `>4KB` is never proof
  (ARM-289). Leave Pixel empty/`optional` when DEMO + GAMELOG already kill the claim.
- Record the feature ID and the entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet
  precondition. Do not report a skipped entry point as verified through a
  different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph on the user-visible
behaviour, then exactly four H2 sections in order:

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with <harness>`
4. `Gotchas`

Sub-features stay `id: observable end state`. Encode rung choice and minimum
evidence (GAMELOG / DEMO / named-pixel) inside those four H2s only. Default
minimum is DEMO + GAMELOG; pixel cells are named contracts or `optional`.

## Join & leave

- [Joining the world](./join-welcome.md) — connect, be welcomed, see every player.
- [Leaving the world](./disconnect-despawn.md) — despawn on the survivor's screen
  and the latched disconnect reason.
- [Server liveness](./heartbeat-liveness.md) — heartbeat ticks, three-interval
  liveness window, loud abandon of a silent server.

## Movement

- [Move-to walk](./move-to-walk.md) — **retired** (ARM-239). Player polyline walk
  is gone; see [Polish](./polish/README.md) for graduated action-movement e2e.
- [Two clients see each other walk](./two-clients-see-each-other.md) — M0 both
  directions, named-pixel still-camera band, server pose (DEMO + GAMELOG default).
- [WASD direction move](./wasd-move.md) — wish samples + server pose. WASD is the
  only movement gesture (ARM-145 / ARM-239).
- [Arena collision and height](./arena-collision-height.md) — Ring of Trials
  wall block, ramp height, jump/land (`ARENA COLLISION DEMO OK`, ARM-259).
- [Rejected and malformed intents](./rejected-intents.md) — validation, `error`
  frames, log records.

## Items & gathering

- [Two clients race for one item](./contested-pickup.md) — M1: one winner, drop,
  `item_spawned` coordinates.
- [Equip the join-kit weapon](./equip-weapon.md) — M3 equip / unequip.
- [Gather then craft](./gather-craft.md) — M4 product; `gather_craft_demo.ps1` is
  a fail-closed stub (ARM-287). Live gather via `gather_error_demo`.
- [Mine, smelt, craft sword](./craft-cast-demo.md) — M12 split (ARM-290):
  `mine_smelt_craft_demo` + `cast_bar_demo`. `craft_cast_demo.ps1` is fail-closed.
- [Right-click a tree, chop it or be told why not](./gather-refusal.md) — ARM-147
  gather gate refusal.
- [Admin give class kits](./admin-give-class-kits.md) — `/give` via `-admin`
  (retired `-seed-class-kits`).

## Combat

- [Kill and respawn](./combat-kill-respawn.md) — M5 death/respawn (Go) plus live
  NPC melee via `dummy_attack` / `heal_wounded`. `combat_demo.ps1` is a fail-closed stub (ARM-284).
- [Tab targeting](./tab-targeting.md) — M6c select with ring chrome; no auto-attack.
- [Right-click basic attack](./right-click-basic-attack.md) — M6f hostile engage;
  friendly refuse.
- [Cast effect on target](./cast-effect-on-target.md) — M6h cast flash / refuse.
- [Tab combat loop](./tab-combat-loop.md) — M6i split (ARM-290): `wasd` /
  `dummy_cast` / `dummy_attack` / `heal_wounded`. `tab_combat_demo.ps1` is fail-closed.

## Quests

- [Quest demo: sticks for miner kit](./quest-demo.md) — M9 deliver sticks
  (`QUEST DEMO OK`).
- [Enemy quest demo: party, imps, Imp Patrol](./enemy-quest-demo.md) — M11 split
  (ARM-290): `enemy_party` / `enemy_midchase` / `enemy_quest_turnin`. Kitchen-sink
  `enemy_quest_demo.ps1` is fail-closed.
## Polish (M13 action movement)

Graduated e2e home. Prop presentation is **mock-first** (no marqued). Wire and
authority claims stay Go / existing live demos.

- [Polish index](./polish/README.md) — layout, drivers, markers
- [ADR 0001 movement authority](./polish/adr-0001-movement-authority.md)
- [ADR 0002 sim tick / cast timing](./polish/adr-0002-sim-tick-and-cast-timing.md)
- [ADR 0003 movement wire](./polish/adr-0003-movement-wire.md)
- [ADR 0004 jump](./polish/adr-0004-jump.md)
- [ADR 0005 ability locomotion](./polish/adr-0005-ability-locomotion.md)
- [Prop: player character](./polish/props/player-character.md) — shared
  `player_character.tscn` mock e2e (`PASS: player_character prop mock`)
