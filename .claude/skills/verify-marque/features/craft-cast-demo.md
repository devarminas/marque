# Mine, smelt, craft sword, cast bar (M12)

One client wears a miner kit, mines the starter rock for `copper_ore`, smelts it at
the starter smelter into `copper_bar`, crafts `copper_bar` + seeded `sticks` into
`sword`, then swaps to mage and proves fireball cast-bar resolve plus one walk
interrupt outside grace.

## Sub-features

- `mine-copper` — GAMELOG `gather_resolved` kind `copper_ore`; DEMO shot 2 bag holds
  ore; rock at (2, 3).
- `smelt-bar` — GAMELOG `use` from `copper_ore` to `copper_bar` with `station`; DEMO
  shot 3 bag holds bar and no ore.
- `craft-sword` — GAMELOG `use` to `sword`; DEMO shot 4 bag holds sword and no bar /
  sticks.
- `cast-resolve` — GAMELOG `cast_begin` then `cast` / `cast_effect` for fireball;
  DEMO `castbar visible=1` then `visible=0` and `castok`.
- `cast-interrupt` — GAMELOG `cast_cancelled` with cause `move` (or `move_to`); DEMO
  `castcancel` and no success effect for that cast.
- `demo-pass` — harness exits 0 with `CRAFT CAST DEMO OK` as its last line, and the
  client prints `DEMO done`.

## How to get to it (user POV)

- Join with a miner set and pickaxe. Right-click the rock at (2, 3). Walk to the
  smelter at (0, 3), left-click `copper_ore` then the smelter. Left-click `copper_bar`
  twice while holding `sticks` to craft a `sword`. Wear a mage set, select the red
  dummy, cast fireball and stand still for the cast bar; cast again and WASD-walk
  early to interrupt outside the last-two-tick grace.

## Driving it with scripts/craft_cast_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/craft_cast_demo.ps1`.
- Marker: `CRAFT CAST DEMO OK` on the **last line** of stdout. Exit code must also
  be 0.

The script builds marqued with miner + sticks + mage `-join-kit` kinds, warms Godot,
starts the server on a free port, launches one windowed client with
`--craft-cast-shots`, and asserts both DEMO inventory/cast lines and GAMELOG
gather / use / cast_begin / cast / cast_effect / cast_cancelled.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-craft-cast`: six PNGs, client
stdout/stderr, and `server.stdout.ndjson`.

## Gotchas

- **Sticks are join-kit seeded.** The milestone proves mine→smelt→sword, not tree
  chop. Without `-join-kit sticks` the sword recipe cannot start.
- **Station range is 0.5.** After mining at (2, 3) the client must walk to the
  smelter before use-on; a same-spot smelt refuses out of range.
- **Interrupt uses `move`, not only `move_to`.** The demo steers with
  `request_move` so GAMELOG cause is `move`. Grace is the last two ticks of an
  8-tick fireball; walk earlier.
- **Class swap mid-run.** Unequip the miner set before wearing mage gear or fireball
  is refused with `needs_class`.
