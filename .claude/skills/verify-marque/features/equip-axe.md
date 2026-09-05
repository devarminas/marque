# Equip the join-kit axe

The M3 milestone: open equipment on the left, right-click the seeded axe to wear
it in the weapon slot, then activate the worn slot to unequip back to the bag.

## Sub-features

- `equip-panel-left` — the equipment panel opens on the left side of the viewport
  (DEMO `equipopen` line and shot 1 screenshot).
- `equip-intent` — one `equip` in the GAMELOG, bag slot 0 to worn `weapon`, kind
  `axe`; client shot 2 shows the weapon slot occupied and the bag empty.
- `unequip-intent` — one `unequip` in the GAMELOG, worn `weapon` back to bag slot
  0; client shot 3 shows the weapon slot empty and the axe in the bag again.
- `demo-pass` — harness exits 0 with `EQUIP DEMO OK` as its last line, and the
  client prints `DEMO done`.

## How to get to it (user POV)

- Press **E** to open equipment on the left. Right-click the axe in the inventory
  (or drag it onto the weapon slot). The axe appears in the weapon slot and
  leaves the bag. Click the occupied weapon slot to unequip; the axe returns to
  the bag.

## Driving it with scripts/equip_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/equip_demo.ps1`.
- Marker: `EQUIP DEMO OK` on the **last line** of stdout. Exit code must also be 0.

The script builds marqued, warms Godot once, starts the server on a free port,
launches one windowed client with `--equip-shots`, and asserts:

- Server layer: exactly one `equip` and one `unequip` for the joining player, with
  the fields above; no `equip_rejected` or `unequip_rejected`.
- Client layer: `DEMO equipopen` proves the panel is left-anchored; shots 2 and 3
  `DEMO worn` / `DEMO invslot` lines match the post-equip and post-unequip states.
- Three PNGs over 4KB each and `DEMO done` on the client.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-equip`: three PNGs,
`client.stdout.log`, `client.stderr.log`, and `server.stdout.ndjson`.

## Gotchas

- **Single client.** Unlike M0/M1 demos, this milestone needs only one connection.
  The join kit already seeds the axe; no ground item or second player is required.
- **Right-click equips.** Drag onto weapon is wired in M3c but this demo uses
  right-click on bag slot 0, which is the simplest user path that sends `equip`.
- **Wait for restatement.** The client captures shot 2 only after the server's
  `equipment` and `inventory` frames have been applied, not merely after the click.
- **Panel opacity.** Keep scripted clicks off the inventory panel rect when adding
  new steps; both panels swallow clicks (M1k, M3b).
- **Equip onto an occupied worn slot does not reject.** The server swaps the two
  items, returning the displaced one to the bag, and the `equip` log line carries a
  `displaced` field instead of a rejection event. The demo never exercises this
  path; a probe that sends a second equip onto a worn slot should expect the swap,
  not `equip_rejected`.
