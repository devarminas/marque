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

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- Assert both evidence layers when the claim spans them: what the client drew
  (`DEMO` lines, PNGs) and what the server believes (GAMELOG). Name the minimum
  set inside Sub-features, Driving, or Gotchas. Do not invent a fifth H2.
- Every screenshot assertion names the pixel fact that would be missing if the
  claim were false.
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
evidence (GAMELOG / DEMO / pixel) inside those four H2s only.

## Join & leave

- [Joining the world](./join-welcome.md) — connect, be welcomed, see every player.
- [Leaving the world](./disconnect-despawn.md) — despawn on the survivor's screen
  and the latched disconnect reason.
- [Server liveness](./heartbeat-liveness.md) — heartbeat ticks, three-interval
  liveness window, loud abandon of a silent server.

## Movement

- [Move-to walk](./move-to-walk.md) — `move_to` intent, path, walk, arrival; bare
  ground left-click sends nothing.
- [Two clients see each other walk](./two-clients-see-each-other.md) — M0 both
  directions, still-camera pixel control, server `arrived`.
- [WASD direction move](./wasd-move.md) — M6g server-authoritative `move`, sticky
  steer. WASD is the only movement gesture (ARM-145).
- [Rejected and malformed intents](./rejected-intents.md) — validation, `error`
  frames, log records.

## Items & gathering

- [Two clients race for one item](./contested-pickup.md) — M1: one winner, drop,
  `item_spawned` coordinates.
- [Equip the join-kit weapon](./equip-weapon.md) — M3 equip / unequip.
- [Gather then craft](./gather-craft.md) — M4 equip, contested tree, craft
  logs→sticks.
- [Right-click a tree, chop it or be told why not](./gather-refusal.md) — ARM-147
  gather gate refusal.
- [Seed class kits on the ground](./seed-class-kits.md) — M7g `-seed-class-kits`.

## Combat

- [Kill and respawn](./combat-kill-respawn.md) — M5 death/respawn (Go) plus live
  NPC melee via `dummy_attack` / `tab_combat`. `combat_demo.ps1` is retired.
- [Tab targeting](./tab-targeting.md) — M6c select with ring chrome; no auto-attack.
- [Right-click basic attack](./right-click-basic-attack.md) — M6f hostile engage;
  friendly refuse.
- [Cast effect on target](./cast-effect-on-target.md) — M6h cast flash / refuse.
- [Tab combat loop](./tab-combat-loop.md) — M6i fireball, heal, attack, WASD.

## Quests

- [Quest demo: sticks for miner kit](./quest-demo.md) — M9 deliver sticks
  (`QUEST DEMO OK`).
- [Enemy quest demo: party, imps, Imp Patrol](./enemy-quest-demo.md) — M11
  party/kill/quest **outcome** (`ENEMY QUEST DEMO OK`); not Imp chase
  (outcome-not-chase).
