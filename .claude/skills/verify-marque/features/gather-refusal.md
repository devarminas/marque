# Right-click a tree, chop it or be told why not

ARM-147 makes gathering a right-click gesture and gives every server refusal a place
on screen. Right-click a resource node and the player walks there and chops. Right-click
it with no matching class and the player reads `usable tool not equipped` low on the
screen, which clears itself after four seconds. Left-click on a node now sends nothing.

## Sub-features

- `gather-right-click` — a right-click on a resource node sends one `gather` intent.
  `GroundPicker.node_gather_clicked` carries it; `node_clicked` no longer exists.
- `gather-left-click-inert` — a left-click on a resource node sends no `gather`. The
  server logs no second accepted `gather` for that player.
- `gather-refusal-visible` — the class gate's `error` frame reaches the `ErrorHud`
  label as the exact text `usable tool not equipped`, and GAMELOG records
  `gather_rejected` with reason `needs_class`.
- `gather-refusal-clears` — the label empties about four seconds later with no further
  input, driven by the scene-authored one-shot `Timer` under `UI/ErrorHud`.
- `gather-success-silent` — a gather that resolves yields `logs`, grants
  `woodcutting` XP, depletes the node, and leaves the error label empty.

## How to get to it (user POV)

- Join with an empty bag. Right-click the seeded tree at (5, 0). Nothing is gathered
  and the refusal text appears above the hotbar.
- Pick up a lumberjack set from the ground (`forester_cap`, `forester_shirt`,
  `forester_trousers`, `lumberjack_axe`), open the bag with `I`, right-click each
  piece to wear it. The class restatement turns the player into a Lumberjack.
- Right-click the tree again. The player walks there and chops, and `logs` land in
  the bag.

## Driving it with scripts/gather_error_demo.ps1

Preconditions:

- `DOCTOR OK`, a real desktop session, and a warmed `client/.godot/`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/gather_error_demo.ps1`.
- Marker: `GATHER ERROR DEMO OK` on the **last line** of stdout, with exit code 0.

The script builds marqued, starts it on a free port with four `-item` seeds placing a
lumberjack set between spawn and the tree, and runs one windowed client in
`--gather-error-shots` mode. `DefaultJoinKit` stays empty, so the no-tool case is
reached by joining, not by patching the server.

Three frames land in `-OutDir`, default `$env:TEMP\marque-gather-error`:

| Frame | What it must show |
|---|---|
| `a_1.png` | the refusal text on screen, right after an unarmed right-click |
| `a_2.png` | the same view with the text gone |
| `a_3.png` | the depleted tree and `logs` in the bag, error label empty |

Both layers are asserted. Client layer: the `DEMO errortext`, `DEMO errorhud`,
`DEMO errorcleared`, `DEMO leftclickgathers`, `DEMO class` and `DEMO gathered` lines,
plus a pixel comparison between frames 1 and 2 over the label's own rect, with a
control band of the same scanlines to its left. The label band must differ, the
control band must not, and either reading zero pixels is a failure rather than a
pass. Server layer: exactly one `gather_rejected` with reason
`needs_class`, exactly one accepted `gather`, exactly one `gather_resolved` yielding
`logs`, and a `skill_xp` naming `woodcutting`.

## Gotchas

- **The refused gather never logs `gather`.** A refusal on receipt logs
  `gather_rejected` only, so "exactly one accepted `gather`" is what proves the left
  click sent nothing, not a count of `gather_rejected`.
- **Empty join kit.** `DefaultJoinKit` is empty since M7. Any recipe that assumes a
  bag axe at join, `scripts/gather_craft_demo.ps1` among them, cannot reach its
  scenario. Seed the kit on the ground with `-item x,z,kind` and pick it up.
- **The linger window is a tuning knob.** The harness accepts 3000..9000ms around the
  authored 4.0s `wait_time` rather than asserting the number, so a retune does not
  turn the demo red for the wrong reason.
- **The label band is fixed at 1280x720.** The comparison rectangle is authored
  against the project's default viewport and against `UI/ErrorHud`'s own offsets,
  which put the label at (400, 612)-(880, 644), four pixels clear of the hotbar. A
  resized window or a moved label makes the band assertion meaningless, so move both
  together.
