# Quest demo: stick for miner kit

M9 live path: seed a `stick` via `-join-kit`, talk to the seeded `quest_giver`,
accept Bring a Stick, give the stick through the give panel, and land the miner
set kinds in the bag with the quest marked complete. `DefaultJoinKit` stays empty;
combat and Progression are not involved.

## Sub-features

- `quest-seed-stick` — marqued starts with `-join-kit stick`; `server_started`
  names that join kit; `join_seeded` places `stick` in bag slot 0.
- `quest-accept` — client `DEMO accepted bring_a_stick active` and one GAMELOG
  `quest_accepted` for that player/quest.
- `quest-give-rewards` — after give, DEMO invslots hold the miner reward kinds
  (`prospector_jacket`, `prospector_boots`, `prospector_helm`, `prospector_legs`,
  `pickaxe`) and no `stick`; GAMELOG `quest_completed` consumes `stick`.
- `quest-log-complete` — shot 3 `DEMO questlog` reports `bring_a_stick complete`.
- `demo-pass` — harness exits 0 with `QUEST DEMO OK` as its last line, and the
  client prints `DEMO done`.

## How to get to it (user POV)

- Join a server whose bag was seeded with a singular `stick` (not craft `sticks`).
- Left-click the neutral `quest_giver`, accept Bring a Stick, talk again so the
  give panel opens, then click the stick offer. The miner kit lands in the bag
  and the quest log shows complete.

## Driving it with scripts/quest_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/quest_demo.ps1`.
- Marker: `QUEST DEMO OK` on the **last line** of stdout. Exit code must also be 0.

The script builds marqued, warms Godot once, starts the server on a free port with
`-join-kit stick` (quest_giver is always seeded; join kit is not the wardrobe
DefaultJoinKit), launches one windowed client with `--quest-shots`, and asserts:

- Server layer: `join_seeded` for `stick`, one `quest_accepted`, one
  `quest_completed` with `consume=stick` and five rewards; no talk/dialog/give
  rejects.
- Client layer: `DEMO accepted` / `DEMO complete`, shot 1 bag holds `stick`,
  shot 3 bag holds miner kinds only, shot 3 questlog is complete.
- Three PNGs over 4KB each and `DEMO done` on the client.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-quest`: three PNGs,
`client.stdout.log`, `client.stderr.log`, and `server.stdout.ndjson`.

## Gotchas

- **`stick` ≠ `sticks`.** Quest deliver kind is singular `stick`. M4 craft yields
  `sticks`. Seeding the wrong kind fails give with `wrong_item`.
- **Empty DefaultJoinKit.** Proof uses `-join-kit stick` only. Do not patch
  `DefaultJoinKit` with wardrobe.
- **Talk then re-talk for give.** Accept closes dialog. Give UI opens on a later
  talk while the quest is `active` (ARM-191). Give itself is immediate and
  range-gated (`GiveRange` == `TalkRange`); the first talk walks the player in.
- **Cite.** Pattern matches `scripts/equip_demo.ps1` / `gather_craft_demo.ps1`
  and ARM-143 seed style (`scripts/seed_class_kits_demo.ps1`,
  `features/seed-class-kits.md`): flag seed, DEMO lines, GAMELOG asserts, last-line
  marker.
