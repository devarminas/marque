# Polish features (M13 action movement)

Graduated action-movement e2e for M13. Prop presentation runs against a **mock
(no marqued)**. Live marqued / Go only for wire and authority claims a mock
cannot falsify.

## Layout

| Path | Role |
|---|---|
| [adr-0001-movement-authority.md](./adr-0001-movement-authority.md) | Authority, illegal samples, no player path |
| [adr-0002-sim-tick-and-cast-timing.md](./adr-0002-sim-tick-and-cast-timing.md) | 40 ms tick, cast grace wall-clock |
| [adr-0003-movement-wire.md](./adr-0003-movement-wire.md) | `move` / `pose` names, `move_to` refuse |
| [adr-0004-jump.md](./adr-0004-jump.md) | Jump ballistic + mid-air refuse |
| [adr-0005-ability-locomotion.md](./adr-0005-ability-locomotion.md) | movable / rooted / interrupt_on_move |
| [props/player-character.md](./props/player-character.md) | Shared `player_character.tscn` mock prop e2e |

Prototype [move-to-walk](../move-to-walk.md) is **retired** (ARM-239). Do not
drive it. Presentation and camera/anim asserts live in the prop mock above.
WASD live demo remains under [wasd-move](../wasd-move.md) for wish+pose on the
wire.

## Driving (default)

```bash
godot --headless --path client --script res://tests/run_tests.gd
```

Required markers: exit 0, last line `PASS: N assertion(s) held across M suite(s)`,
and during the run `PASS: player_character prop mock`.

Wire/authority claims: from `server/`, `CGO_ENABLED=1 go test -race ./...`
(named tests in each `adr-000N-*.md`). Existing live demos (`wasd_demo.ps1`,
etc.) are not multiplied for polish.
