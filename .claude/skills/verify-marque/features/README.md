# Marque verification map

This directory is the maintained source for verifying the user-facing behaviour of
Project Marque. Read this index before driving the app, then use the matching feature
file as the recipe. The harness itself — launch, doctor, drive, evidence, cleanup —
is documented in [../SKILL.md](../SKILL.md).

## Baseline preconditions

- `doctor.ps1` reports `DOCTOR OK`.
- On a fresh checkout, the Godot caches are warmed once:
  `godot --headless --path client --editor --quit` (run.ps1 self-heals this).
- Anything windowed runs in a real desktop session; headless runs render nothing.
- Servers always bind `127.0.0.1:0` and announce the port in their `server_started`
  GAMELOG line. Never assume a fixed port.
- Every run owns its own processes and stops them by PID.

## Driving conventions

- Screenshot prefixes are absolute host paths; two clients share one `user://`.
- Resolve player ids from each client's `DEMO joined` line, never from launch order —
  the clients race to connect.
- A run passed only if it exited 0 **and** its marker line printed
  (`VERIFY HARNESS OK`, `TWO CLIENT DEMO OK`, `INTEROP OK`, `PASS:`). Neither alone
  proves anything — a suite can print `PASS:` about itself, and one here did. Take
  the marker from the last line of the output rather than from a grep.
- Treat every command as literal; keep flags and quoting unchanged.
- Do not remove proof artifacts during cleanup. The harness that wrote them empties
  its own output directory at the start of its *next* run, so copy anything worth
  keeping before rerunning.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- Assert both evidence layers: what the client drew (`DEMO pos` lines, PNGs) and what
  the server believes (GAMELOG events). The client interpolates paths by itself, so
  the two can disagree, and a claim proven on one layer only is half-proven.
- Every screenshot assertion names the specific pixel fact that would be missing if
  the claim were false — a cast shadow, a second body, a displacement between two
  named frames. "The screenshot looks right" is not an assertion.
- Record the feature ID and the entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph on the user-visible
behaviour, then exactly four H2 sections in order: `Sub-features`,
`How to get to it (user POV)`, `Driving it with <harness>`, `Gotchas`.

## Features

- [Joining the world](./join-welcome.md) — connect, be welcomed, see every player.
- [Click to move](./click-to-move.md) — the ground click, the path, the walk, the
  arrival.
- [Two clients see each other walk](./two-clients-see-each-other.md) — the M0
  milestone, both directions, with the still-camera pixel control and the server's
  own `arrived` events.
- [Rejected and malformed intents](./rejected-intents.md) — validation, `error`
  frames, and what the log records.
- [Leaving the world](./disconnect-despawn.md) — despawn on the survivor's screen
  and the latched disconnect reason.
- [Two clients race for one item](./contested-pickup.md) — the M1 milestone: one item,
  two clicks on the same server tick, exactly one winner; plus the drop and the
  `item_spawned` coordinates nothing else in this repo asserts.
- [Equip the join-kit axe](./equip-axe.md) — the M3 milestone: open equipment on
  the left, equip the seeded axe, see it in the weapon slot, unequip back to the bag.
- [Gather then craft](./gather-craft.md) — the M4 milestone: equip, race a tree
  for one logs yield, craft logs→sticks; contested second gatherer gets nothing.
- [Kill and respawn](./combat-kill-respawn.md) — the M5 milestone: out-of-range
  click-attack, walk-in hits of 10 to death, death overlay, respawn to HP 100,
  act again.
- [Server liveness](./heartbeat-liveness.md) — the M2c milestone: heartbeat ticks,
  the three-interval liveness window, and the loud abandon of a silent server.
