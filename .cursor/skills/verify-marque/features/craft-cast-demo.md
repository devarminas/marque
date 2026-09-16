# Mine, smelt, craft sword + cast bar (M12, ARM-290 split)

M12 live proof is two focused demos. The kitchen-sink `craft_cast_demo` is
**retired** (ARM-290 fail-closed stub).

## Sub-features

- `mine-copper` — GAMELOG `gather_resolved` kind `copper_ore`; DEMO shot 2 bag holds
  ore; rock at (2, 3). Driver: `mine_smelt_craft_demo.ps1`.
- `smelt-bar` — GAMELOG `use` from `copper_ore` to `copper_bar` with `station`; DEMO
  shot 3 bag holds bar and no ore.
- `craft-sword` — GAMELOG `use` to `sword`; DEMO shot 4 bag holds sword and no bar /
  sticks.
- `cast-resolve` — GAMELOG `cast_begin` then `cast` / `cast_effect` for fireball;
  DEMO `castbar visible=1` then `visible=0` and `castok`. Driver: `cast_bar_demo.ps1`.
- `cast-interrupt` — GAMELOG `cast_cancelled` with cause `move`; DEMO
  `castcancel` and no success effect for that cast.
- `demo-pass` — each harness exits 0 with its OK marker last; client prints `DEMO done`.

## How to get to it (user POV)

- Join with a miner set and pickaxe. Right-click the rock at (2, 3). Walk to the
  smelter at (0, 3), left-click `copper_ore` then the smelter. Left-click `copper_bar`
  twice while holding `sticks` to craft a `sword`. Wear a mage set, select the red
  dummy, cast fireball and stand still for the cast bar; cast again and WASD-walk
  early to interrupt outside the last-two-tick grace.

## Driving it with the ARM-290 demos

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Mine/smelt/craft: `powershell -ExecutionPolicy Bypass -File scripts/mine_smelt_craft_demo.ps1`.
  Marker: `MINE SMELT CRAFT DEMO OK` on the last line. Exit 0.
- Cast bar: `powershell -ExecutionPolicy Bypass -File scripts/cast_bar_demo.ps1`.
  Marker: `CAST BAR DEMO OK` on the last line. Exit 0.
- Do **not** drive `scripts/craft_cast_demo.ps1` — fail-closed stub (ARM-290).

Both harnesses build marqued with `-admin` (empty join kit), warm Godot, and
`/give` the needed kinds via the admin bus. Default proof is DEMO + GAMELOG
(ARM-289). PNGs are artifacts only. **Reviewer evidence:** screenshot of bag /
recipe state at rest after craft. Cast-bar appear/resolve or walk-interrupt is
video or ordered frames (`--record-frames` or copy demo shots). Attach with
`review-evidence.sh`.

## Gotchas

- **Sticks come from admin `/give`.** The mine→smelt→sword unit proves crafting, not
  tree chop. Without `/give sticks` (under `-admin`) the sword recipe cannot start.
- **Station range is 0.5.** After mining at (2, 3) the client must walk to the
  smelter before use-on; a same-spot smelt refuses out of range.
- **Interrupt uses `cause=move` only.** The cast-bar demo steers with `request_move`
  (wish+pose); GAMELOG cancel cause is `move`, never `move_to`.
- **Split units are the green path.** Agents must not treat the retired kitchen-sink
  marker as required for green.
