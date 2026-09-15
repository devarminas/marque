# Enemy quest demo: party, imps, Imp Patrol (M11, ARM-290 split)

M11 live path is three focused demos. The kitchen-sink `enemy_quest_demo` is
**retired** (ARM-290 fail-closed stub).

**chase-visibility.** Mid-chase is its own unit (`enemy_midchase_demo.ps1`):
`DEMO midchase` plus shared `DEMO npc` / `DEMO anim` lines. The client waits
until an imp reports `walking=1` or `has_path=1`. The harness requires that, or
≥0.5u imp displacement between shots 1 and 2. That proves client-side chase
polyline state, not walk-clip playback.

## Sub-features

- `enemy-quest-party` — leader invites, member accepts; both report `DEMO party`
  with two members; GAMELOG has `party_joined` before kill credit.
  Driver: `enemy_party_demo.ps1`.
- `enemy-quest-accept` — both clients print `DEMO accepted slay_imps active` and
  the server logs `quest_accepted` for each. Covered by party + turn-in demos.
- `enemy-quest-mid-chase` — print `DEMO midchase` and prove chase visibility
  via `walking=1`, `has_path=1`, or ≥0.5u imp displacement.
  Driver: `enemy_midchase_demo.ps1`.
- `enemy-quest-camp-kills` — at least five `npc_despawned` events for kind `imp`
  naming camp `starter_town_imps`. Driver: `enemy_quest_turnin_demo.ps1`.
- `enemy-quest-party-credit` — both players reach `quest_kill_progress` count 5,
  and at least one tick credits both members. Driver: turn-in demo; also Go unit.
- `enemy-quest-turn-in` — both print `DEMO complete slay_imps`; GAMELOG has one
  `quest_completed` each; final shot bags hold knight reward kinds.
- `demo-pass` — each harness exits 0 with its OK marker last; clients print
  `DEMO done`.

Minimum evidence for the load-bearing claims:

| Claim | GAMELOG | DEMO | Pixel |
|---|---|---|---|
| Party formed | `party_joined` | `DEMO party` (2 members) | optional |
| Quest accepted | `quest_accepted` ×2 | `DEMO accepted slay_imps active` | optional |
| Mid-chase NPC state | optional | `DEMO midchase`; `DEMO npc`/`DEMO anim`; walking, has_path, or ≥0.5u | optional |
| Camp kills | ≥5 `npc_despawned` kind `imp` camp `starter_town_imps` | kill/progress lines if present | optional |
| Party kill credit | `quest_kill_progress` count 5 each; shared-credit tick | objective `(5/5)` | optional |
| Turn-in | `quest_completed` ×1 each | `DEMO complete`; reward kinds | optional |

## How to get to it (user POV)

- Join a server seeded with a knight bag kit. Form a party (invite / accept).
- Talk to the Imp Patrol giver, accept the quest, kill five Imps from the camp
  east of spawn (party members share progress map-wide). Talk again and turn in
  when the log shows `(5/5)`.

## Driving it with the ARM-290 demos

Default driver rungs are the three live demos below. Lower rungs cover store and
intent pieces in Go; they do not replace the outcome pass. Do not mint a new demo
for another kill-quest id. Parameterize Go / thin WS instead.

Preconditions:

- `DOCTOR OK`; a real desktop session; nothing else importing `client/.godot`.
- Party + accept: `powershell -ExecutionPolicy Bypass -File scripts/enemy_party_demo.ps1`
  → `ENEMY PARTY DEMO OK`
- Mid-chase: `powershell -ExecutionPolicy Bypass -File scripts/enemy_midchase_demo.ps1`
  → `ENEMY MIDCHASE DEMO OK`
- Kills + turn-in: `powershell -ExecutionPolicy Bypass -File scripts/enemy_quest_turnin_demo.ps1`
  → `ENEMY QUEST TURNIN DEMO OK`
- Do **not** drive `scripts/enemy_quest_demo.ps1` — fail-closed stub (ARM-290).

Each script builds marqued with `-admin` (no join-kit forest), warms Godot, and
`/give`s the knight set via the admin bus.

## Gotchas

- **chase-visibility is polyline, not clip.** `walking=1` / `has_path=1` prove
  unfinished path state on the client. `DEMO anim` may still print `none`.
- **Knight kit is admin `/give`.** `DefaultJoinKit` stays empty; harnesses start
  with `-admin`. Do not pass a `-join-kit` forest.
- **Party credit is map-wide.** The turn-in harness still requires both clients to
  accept the quest and be party members during credit.
- **Turn-in is talk `turn_in_quest`.** Deliver give is not used.
- **Cite.** Pattern matches `scripts/quest_demo.ps1` and verify-marque two-client
  evidence layout. Do not cite `gather_craft_demo.ps1` (ARM-287) or the retired
  kitchen-sink `enemy_quest_demo.ps1`.
