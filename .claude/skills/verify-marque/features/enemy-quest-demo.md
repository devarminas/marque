# Enemy quest demo: party, imps, Imp Patrol

M11 live path: two clients join with a knight kit, party up, accept `slay_imps`
from `imp_quest_giver`, kill the starter-town Imp camp until both logs read
`Slay 5 imps (5/5)`, turn in, and land the knight reward kinds. Party kill
credit is asserted on the GAMELOG: both members receive `quest_kill_progress`
on the same tick while `party_joined` already exists.

## Sub-features

- `enemy-quest-party` — leader invites, member accepts; both report `DEMO party`
  with two members; GAMELOG has `party_joined` before kill credit.
- `enemy-quest-accept` — both clients print `DEMO accepted slay_imps active` and
  the server logs `quest_accepted` for each.
- `enemy-quest-camp-kills` — at least five `npc_despawned` events for kind `imp`
  naming camp `starter_town_imps`.
- `enemy-quest-party-credit` — both players reach `quest_kill_progress` count 5,
  and at least one tick credits both members.
- `enemy-quest-turn-in` — both print `DEMO complete slay_imps`; GAMELOG has one
  `quest_completed` each; shot 3 bags hold knight reward kinds.
- `demo-pass` — harness exits 0 with `ENEMY QUEST DEMO OK` as its last line, and
  both clients print `DEMO done`.

## How to get to it (user POV)

- Join a server seeded with a knight bag kit. Form a party (invite / accept).
- Talk to the Imp Patrol giver, accept the quest, kill five Imps from the camp
  east of spawn (party members share progress map-wide). Talk again and turn in
  when the log shows `(5/5)`.

## Driving it with scripts/enemy_quest_demo.ps1

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/enemy_quest_demo.ps1`.
- Marker: `ENEMY QUEST DEMO OK` on the **last line** of stdout. Exit code must
  also be 0.

The script builds marqued, warms Godot once, starts the server on a free port
with a repeated `-join-kit` knight set, launches two windowed clients with
`--enemy-quest-shots` and `--enemy-quest-role leader|member`, and asserts:

- Server layer: `party_joined`; five-plus camp `npc_despawned` imps; per-player
  `quest_accepted`, five `quest_kill_progress`, one `quest_completed`; shared
  credit tick; no party/talk/dialog rejects.
- Client layer: accept / killsready / complete DEMO lines, party membership,
  shot 2 objective `(5/5)`, shot 3 complete + knight kinds, three PNGs each
  over 4KB, and `DEMO done`.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-enemy-quest`.

## Gotchas

- **Knight kit is a harness seed.** `DefaultJoinKit` stays empty; the demo
  passes five `-join-kit` flags. Clients equip into class `knight` before
  fighting.
- **Party credit is map-wide.** The harness still requires both clients to
  accept the quest and be party members during credit; both help kill so the
  tank survives Imp multi-pull.
- **Turn-in is talk `turn_in_quest`.** Deliver give is not used. The dialog
  Accept button relabels to Turn in when that option is present.
- **Cite.** Pattern matches `scripts/quest_demo.ps1` / `gather_craft_demo.ps1`
  and verify-marque two-client evidence layout.