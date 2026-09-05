# Gather then craft (contested tree)

The M4 milestone: two clients equip the join-kit axe, race the seeded tree for
one `logs` yield, and the winner crafts `logs`→`sticks` via two-click use-on.
The second gatherer on that depletion does not double the resource.

## Sub-features

- `equip-before-gather` — both players wear the axe (GAMELOG `equip`, DEMO
  `worn` on shot 1).
- `contested-gather` — exactly one `gather_resolved` and one `gather_lost` for
  the same node; shot 2 shows `logs` only on the winner and a depleted tree on
  both clients.
- `craft-logs-to-sticks` — one `use` with `from=logs` `to=sticks` for the
  winner; shot 3 bag shows `sticks` and no `logs`.
- `demo-pass` — harness exits 0 with `GATHER CRAFT DEMO OK` as its last line,
  and both clients print `DEMO done`.

## How to get to it (user POV)

- Press **E**, right-click the axe to wear it. Left-click the tree; after the
  walk and chop duration, `logs` land in the bag and the tree depletes. Left-
  click the `logs` slot twice (use-on self) to craft `sticks`.

## Driving it with scripts/gather_craft_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/gather_craft_demo.ps1`.
- Marker: `GATHER CRAFT DEMO OK` on the **last line** of stdout. Exit code must
  also be 0.

The script builds marqued, warms Godot once, starts the server on a free port
(tree is seeded by marqued), launches two windowed clients with
`--gather-craft-shots`, and asserts:

- Server layer: one `equip` per player; one `gather_resolved` and one
  `gather_lost` naming different players and the same node; one `node_depleted`;
  one `use` logs→sticks for the winner only; no `gather_rejected` /
  `use_rejected` / `gather_no_room`.
- Client layer: shot 1 worn axe; shot 2 winner has `logs`, loser does not; shot
  3 winner has `sticks`; both draw the tree as `depleted` after the gather.
- Six PNGs over 4KB each and `DEMO done` on both clients.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-gather-craft`: six PNGs,
both client stdout/stderr logs, and `server.stdout.ndjson`.

## Gotchas

- **Two clients, identical flags.** Like contested pickup: nothing distinguishes
  the clients except window position and shot prefix. The claim is server-side.
- **Tree at (5, 0).** Inventory is bottom-right; the demo unprojects the trunk
  above ground so the gather click clears the opaque panel.
- **Wait for restatement.** Shot 2 waits for `logs` or a depleted node, not
  merely for the click tick offset. Shot 3 waits for `sticks` on the winner.
- **Self-use only.** Craft is two left-clicks on the same `logs` slot
  (`on` equals `slot`). Do not invent a second recipe.
- **Join order picks the winner.** Assert exactly one win, never which client
  label won.
