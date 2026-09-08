# Equip the join-kit weapon

The M3 milestone: open equipment on the right, right-click the seeded sword to
wear it in the `right hand` slot, then activate the worn slot to unequip back to
the bag.

## Sub-features

- `equip-panel-right` — the equipment panel opens on the right side of the
  viewport (DEMO `equipopen` line and shot 1 screenshot).
- `equip-intent` — one `equip` in the GAMELOG, bag slot 0 to worn `right hand`,
  kind `sword`; client shot 2 shows the worn slot occupied and the bag empty.
- `unequip-intent` — one `unequip` in the GAMELOG, worn `right hand` back to bag
  slot 0; client shot 3 shows the worn slot empty and the sword in the bag again.
- `demo-pass` — harness exits 0 with `EQUIP DEMO OK` as its last line, and the
  client prints `DEMO done`.

## How to get to it (user POV)

- Press **I** to open equipment on the right. Right-click the sword in the
  inventory (or drag it onto the right-hand slot). The sword appears in that slot
  and leaves the bag. Click the occupied slot to unequip; the sword returns to the
  bag.

## Driving it with scripts/equip_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/equip_demo.ps1`.
- Marker: `EQUIP DEMO OK` on the **last line** of stdout. Exit code must also be 0.

The script builds marqued, warms Godot once, starts the server on a free port with
`-join-kit sword`, launches one windowed client with `--equip-shots`, and asserts:

- Server layer: `server_started` names that join kit, one `join_seeded` gives the
  joining player the sword in bag slot 0, and exactly one `equip` and one
  `unequip` follow with the fields above; no `equip_rejected` or
  `unequip_rejected`.
- Client layer: `DEMO equipopen` proves the panel is right-anchored; shots 2 and 3
  `DEMO worn` / `DEMO invslot` lines match the post-equip and post-unequip states.
- Three PNGs over 4KB each and `DEMO done` on the client.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-equip`: three PNGs,
`client.stdout.log`, `client.stderr.log`, and `server.stdout.ndjson`.

## Gotchas

- **Single client.** Unlike M0/M1 demos, this milestone needs only one connection.
  The demo passes `-join-kit sword` so the bag arrives stocked; the shipped
  `DefaultJoinKit` is empty, and no ground item or second player is required.
- **Right-click equips.** Drag onto the worn slot is wired in M3c but this demo
  uses right-click on bag slot 0, which is the simplest user path that sends
  `equip`.
- **Wait for restatement.** The client captures shot 2 only after the server's
  `equipment` and `inventory` frames have been applied, not merely after the click.
- **Panel opacity.** Keep scripted clicks off the inventory panel rect when adding
  new steps; both panels swallow clicks (M1k, M3b).
- **Equip onto an occupied worn slot does not reject.** The server swaps the two
  items, returning the displaced one to the bag, and the `equip` log line carries a
  `displaced` field instead of a rejection event. The demo never exercises this
  path; a probe that sends a second equip onto a worn slot should expect the swap,
  not `equip_rejected`.
