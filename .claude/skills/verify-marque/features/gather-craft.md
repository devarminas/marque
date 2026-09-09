# Gather then craft (contested tree)

The M4 milestone: two clients wear a lumberjack kit (class-gated gather), race the
primary seeded tree at (5, 0) for one `logs` yield, and the winner crafts
`logs`→`sticks` via two-click use-on. The second gatherer on that depletion does not
double the resource. A second starter tree at (-5, 2) is also live; demos still
target (5, 0).

## Sub-features

- `equip-before-gather` — both players wear a matching lumberjack set and tool
  (GAMELOG `equip` / `class`, DEMO worn state on shot 1).
- `contested-gather` — exactly one `gather_resolved` and one `gather_lost` for
  the same node; shot 2 shows `logs` only on the winner and a depleted tree on
  both clients.
- `craft-logs-to-sticks` — one `use` with `from=logs` `to=sticks` for the
  winner; shot 3 bag shows `sticks` and no `logs`.
- `demo-pass` — harness exits 0 with `GATHER CRAFT DEMO OK` as its last line,
  and both clients print `DEMO done`.

## How to get to it (user POV)

- Press **I**, wear a full lumberjack set and `lumberjack_axe` from the bag (or
  ground seeds). Right-click the tree; after the walk and chop duration, `logs`
  land in the bag and the tree depletes. Left-click the `logs` slot twice
  (use-on self) to craft `sticks`.

## Driving it with scripts/gather_craft_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/gather_craft_demo.ps1`.
- Marker: `GATHER CRAFT DEMO OK` on the **last line** of stdout. Exit code must
  also be 0.

The script builds marqued, warms Godot once, starts the server on a free port
(trees are seeded by marqued), launches two windowed clients with
`--gather-craft-shots`, and asserts:

- Server layer: one successful gather contest on the primary tree; one
  `gather_resolved` and one `gather_lost` naming different players and the same
  node; one `node_depleted`; one `use` logs→sticks for the winner only; no
  `gather_rejected` / `use_rejected` / `gather_no_room`.
- Client layer: shot 1 worn lumberjack tool; shot 2 winner has `logs`, loser does
  not; shot 3 winner has `sticks`; both draw the tree as `depleted` after the
  gather.
- Six PNGs over 4KB each and `DEMO done` on both clients.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-gather-craft`: six PNGs,
both client stdout/stderr logs, and `server.stdout.ndjson`.

## Gotchas

- **Two clients, identical flags.** Like contested pickup: nothing distinguishes
  the clients except window position and shot prefix. The claim is server-side.
- **Primary tree at (5, 0).** A second starter tree lives at (-5, 2); both reuse
  `resource_node.tscn` over server positions. Inventory is bottom-right; the demo
  unprojects the trunk above ground so the gather click clears the opaque panel.
  Decorative trees in `world_map` are not gather nodes.
- **Wait for restatement.** Shot 2 waits for `logs` or a depleted node, not
  merely for the click tick offset. Shot 3 waits for `sticks` on the winner.
- **Self-use only.** Craft is two left-clicks on the same `logs` slot
  (`on` equals `slot`). Do not invent a second recipe.
- **Empty join kit / stale harness.** `DefaultJoinKit` is empty since M7. There is
  no wearable kind `axe`; gather needs class `lumberjack` with `lumberjack_axe`.
  `scripts/gather_craft_demo.ps1` still expects a bag `axe` and does not pass
  `-join-kit` / lumberjack `-item` seeds, so the windowed contested-gather recipe
  is currently unreachable until that harness is fixed (product/script fix outside
  this skill directory). Use `scripts/gather_error_demo.ps1` for a live gather
  proof that seeds ground gear.
