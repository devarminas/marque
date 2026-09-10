# Enemy quest demo: party, imps, Imp Patrol

M11 live path: two clients join with a knight kit, party up, accept `slay_imps`
from `imp_quest_giver`, kill the starter-town Imp camp until both logs read
`Slay 5 imps (5/5)`, turn in, and land the knight reward kinds. Party kill
credit is asserted on the GAMELOG: both members receive `quest_kill_progress`
on the same tick while `party_joined` already exists.

**outcome-not-chase.** This recipe proves party, camp kills, and quest complete.
It does not prove Imp chase pathing or walk-anim.

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

Minimum evidence for the load-bearing claims:

| Claim | GAMELOG | DEMO | Pixel |
|---|---|---|---|
| Party formed | `party_joined` | `DEMO party` (2 members) | optional |
| Quest accepted | `quest_accepted` ×2 | `DEMO accepted slay_imps active` | optional |
| Camp kills | ≥5 `npc_despawned` kind `imp` camp `starter_town_imps` | kill/progress lines if present | optional |
| Party kill credit | `quest_kill_progress` count 5 each; shared-credit tick | objective `(5/5)` on shot 2 | optional |
| Turn-in | `quest_completed` ×1 each | `DEMO complete`; shot 3 knight kinds | PNGs >4KB |

Chase / walk-anim is **not** in this table.

## How to get to it (user POV)

- Join a server seeded with a knight bag kit. Form a party (invite / accept).
- Talk to the Imp Patrol giver, accept the quest, kill five Imps from the camp
  east of spawn (party members share progress map-wide). Talk again and turn in
  when the log shows `(5/5)`.

## Driving it with scripts/enemy_quest_demo.ps1

Default driver rung: **live windowed demo** (party choreography + quest UI).
Lower rungs cover store and intent pieces in Go; they do not replace this outcome
pass. Do not mint a new demo for another kill-quest id. Parameterize Go / thin WS
instead (see *Proof ladder* in `../SKILL.md`).

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Run `powershell -ExecutionPolicy Bypass -File scripts/enemy_quest_demo.ps1`.
- Marker: `ENEMY QUEST DEMO OK` on the **last line** of stdout. Exit code must
  also be 0.

The script builds marqued, warms Godot once, starts the server on a free port
with a repeated `-join-kit` knight set, launches two windowed clients with
`--enemy-quest-shots` and `--enemy-quest-role leader|member`, and asserts the
minimum evidence table above plus no party/talk/dialog rejects and `DEMO done`.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-enemy-quest`.

## Gotchas

- **outcome-not-chase.** `ENEMY QUEST DEMO OK` is party / kill / quest outcome
  proof. Imp chase pathing and walk-anim are Go or GAMELOG-only unless a later
  unit asserts them. Do not treat mid-chase pixels as required by this marker.
- **Knight kit is a harness seed.** `DefaultJoinKit` stays empty; the demo
  passes five `-join-kit` flags. Clients equip into class `knight` before
  fighting.
- **Party credit is map-wide.** The harness still requires both clients to
  accept the quest and be party members during credit; both help kill so the
  tank survives Imp multi-pull.
- **Turn-in is talk `turn_in_quest`.** Deliver give is not used. The dialog
  Accept button relabels to Turn in when that option is present.
- **Imp walk animation is unverified.** `npc_imp.tscn` authors an
  `AnimationPlayer` so a missing player no longer silent-no-ops (ARM-228), but
  Imp-compatible walk/idle clips are not wired yet. `has_animation` soft-skips,
  so chase motion is still a root transform only until clips land.
- **Cite.** Pattern matches `scripts/quest_demo.ps1` / `gather_craft_demo.ps1`
  and verify-marque two-client evidence layout.
