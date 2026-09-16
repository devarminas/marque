---
name: verify-marque
description: Drive Project Marque the way a player does — the real marqued Go server plus real Godot 4.7 clients — and prove behavioural claims from the clients' DEMO lines and the server's NDJSON GAMELOG. PNG checks are named-pixel contracts only; screenshot presence is never proof. Use whenever a claim about client or server behaviour needs evidence stronger than a passing unit test.
---

# Verify Marque

Project Marque is a Go WebSocket server (`server/`, binary `marqued`) and a Godot 4.7
Forward+ desktop client (`client/`) speaking one-key JSON messages (wire of record: `server/`, `client/`, and their tests).
This skill is how an agent launches the real stack, drives it like a player, and reads
back what actually happened. It was written against M0 (connect, walk, see each other
walk) and now covers M1 (items, pickup, drop, the contested-pickup demo,
disconnect classification) and M2c (the client's `tick` handling and heartbeat
liveness); `features/README.md` is the maintained map of what is verifiable.

## The standard of proof

**Exit code 0 is never proof.** Two false-pass holes were found in this repo: a scene
suite calling `get_tree().quit(0)` in `_ready` exits 0 with zero assertions and no
`PASS` line, and an infinite loop in a tree-free suite runs during `_initialize`
before any frame is counted, so no frame watchdog fires. Every recipe below therefore
has a marker line, and a run without its marker failed, whatever the exit code said:

| Run | Required marker |
|---|---|
| Headless suite runner | `PASS: N assertion(s) held across M suite(s)` on stdout |
| `scripts/interop_test.ps1` | `INTEROP OK`, plus the `INTEROP RAN:` and `WIRING RAN:` lines |
| `scripts/two_client_demo.ps1` | `TWO CLIENT DEMO OK` |
| `scripts/contested_pickup_demo.ps1` | `CONTESTED PICKUP DEMO OK` |
| `scripts/equip_demo.ps1` | `EQUIP DEMO OK` |
| `scripts/gather_craft_demo.ps1` | **retired** (ARM-287 fail-closed stub). Exits non-zero with a clear message. Drive `gather_error_demo.ps1` for live gather proof. |
| `scripts/craft_cast_demo.ps1` | **retired** (ARM-290 fail-closed stub). Drive `mine_smelt_craft_demo.ps1` / `cast_bar_demo.ps1`. |
| `scripts/mine_smelt_craft_demo.ps1` | `MINE SMELT CRAFT DEMO OK` |
| `scripts/cast_bar_demo.ps1` | `CAST BAR DEMO OK` |
| `scripts/gather_error_demo.ps1` | `GATHER ERROR DEMO OK` |
| `scripts/dummy_cast_demo.ps1` | `DUMMY CAST DEMO OK` |
| `scripts/dummy_attack_demo.ps1` | `DUMMY ATTACK DEMO OK` |
| `scripts/wasd_demo.ps1` | `WASD DEMO OK` |
| `scripts/arena_collision_demo.ps1` | `ARENA COLLISION DEMO OK` |
| `scripts/tab_combat_demo.ps1` | **retired** (ARM-290 fail-closed stub). Drive `wasd_demo.ps1` / `dummy_cast_demo.ps1` / `dummy_attack_demo.ps1` / `heal_wounded_demo.ps1`. |
| `scripts/heal_wounded_demo.ps1` | `HEAL WOUNDED DEMO OK` |
| `scripts/combat_demo.ps1` | **retired** (ARM-284 fail-closed stub). Exits non-zero with a clear message. Drive `dummy_attack_demo.ps1` / `heal_wounded_demo.ps1` instead. |
| `scripts/quest_demo.ps1` | `QUEST DEMO OK` |
| `scripts/enemy_quest_demo.ps1` | **retired** (ARM-290 fail-closed stub). Drive `enemy_party_demo.ps1` / `enemy_midchase_demo.ps1` / `enemy_quest_turnin_demo.ps1`. |
| `scripts/enemy_party_demo.ps1` | `ENEMY PARTY DEMO OK` |
| `scripts/enemy_midchase_demo.ps1` | `ENEMY MIDCHASE DEMO OK` |
| `scripts/enemy_quest_turnin_demo.ps1` | `ENEMY QUEST TURNIN DEMO OK` |
| `scripts/admin_give_class_kits_demo.ps1` | `ADMIN GIVE CLASS KITS DEMO OK` |
| `run.ps1` (this skill) | `VERIFY HARNESS OK` |
| `review-evidence.sh` / `review-evidence.ps1` | `REVIEW CAPTURE OK` / `REVIEW STITCH OK` / `REVIEW ATTACH OK` — last line of that command. Not a behavioural pass. |
| marqued readiness | a `GAMELOG` line with `"ev":"server_started"` |
| each scripted client | `DEMO done` on its stdout |

**A marker line is not proof either. Require both, and read the tail.** A `PASS:`
line is unauthenticated text that any suite can print about itself. M1c's verifier
made a failing suite print `PASS: 999 assertion(s) held across 8 suite(s)` from
inside itself, ran the real interop harness against it, and watched the transcript
parser believe the forgery; only the separate exit-code check turned the run red. So
the rule is exit code **and** the marker, never either alone. Better still, take the
marker from the **last line** of the output instead of grepping for it: all three
PowerShell harnesses here print theirs last, and a grep matches a forgery buried
anywhere in the middle.

**Default proof is DEMO lines + GAMELOG. Both layers, not either alone.** Client
stdout (`DEMO pos`, `DEMO joined`, inventory/cast lines, …) proves what the *client
drew or reported*; the GAMELOG proves what the *server believes*. A server whose tick
loop stopped advancing players can still look fine on the client if the client is
interpolating or predicting from a stale handoff. "The player moved" is proven by
non-zero GAMELOG `move` wishes **and** pose/`DEMO pos` displacement. `arrived` is
NPC path completion only; player `path_assigned` / `move_to` fail closed. Never by
pixels alone and never by a PNG that merely exists.

**PNG is optional and named-pixel only.** A screenshot assertion must name the
specific pixel fact that would be missing if the claim were false — the cast shadow,
the second body, the still-camera quiet band, the label-band differing pixels.
"`a_1.png` exists and is over 4KB" is never proof (ARM-289). Do not steer a recipe
toward soft visual-only passes. If the claim does not need a named-pixel contract,
leave the Pixel column empty or `optional` and prove it with DEMO + GAMELOG.

**Reviewer-facing media is a separate lane.** When the PR changes something a human
should see without launching the client, attach 1–3 screenshots or a short clip to
the GitHub PR after a successful verify run. That attachment is complementary. It
does not replace DEMO + GAMELOG, and file presence still does not pass a claim.
See *Reviewer-facing evidence*.

## Proof ladder

Pick the **lowest falsifying rung** that can kill the claim. Do not climb for comfort.
Stay in one skill: verify-marque owns client and server behaviour together. Do not
split into a client skill and a server skill.

| Rung | Falsifies | Drive |
|---|---|---|
| Go unit | Store, tick, intent rejection, GAMELOG shape | From `server/`: `CGO_ENABLED=1 go test -race ./...` (C toolchain on PATH) |
| Headless Godot | Client frame handling, suites, signals (no pixels) | `godot --headless --path client --script res://tests/run_tests.gd`; full stack via `scripts/interop_test.ps1` |
| Thin WS probe | Wire replies the flag path cannot reach | Throwaway WebSocket client outside the repo (see *Raw protocol probes*) |
| Live windowed demo | DEMO lines + GAMELOG; named-pixel only when a recipe names one | Existing `scripts/*_demo.ps1` only |

**No new windowed demo per quest id.** New quest coverage extends Go, headless, or
thin WS. Do not add `*_demo.ps1`, `*_demo.gd`, or a new `--*-shots` flag for a
quest string. Existing demos stay; they do not multiply with content.
**Exception (ARM-290):** splitting an already-allowlisted kitchen-sink demo into
smaller allowlisted units with one claim each is required when the sink is too
long; update `demo-allowlist.txt` in the same change.

**Evidence kinds** fold into feature recipes (GAMELOG / DEMO / named-pixel), never a
fifth H2. Feature files keep Atlas's four H2s only. Default minimum evidence is
DEMO + GAMELOG; name a pixel contract only when the claim is visual. Name the
default driver rung in `Driving` when the recipe has one.

**outcome-not-chase.** `ENEMY QUEST TURNIN DEMO OK` proves party, camp kills, and quest
complete. It does not prove Imp chase or walk-anim. Chase timing is Go/GAMELOG:
`arrived` with `npc` after a chase path (`TestImpChasePathLogsArrived`). Live
mid-chase remains DEMO npc/anim via `enemy_midchase_demo.ps1`
(`features/enemy-quest-demo.md`).

## Launch

All commands run from the repo root. Go 1.27 and Godot 4.7 (`godot`) are on PATH;
every script here also honours `$env:GODOT` / `$GODOT` as the Godot executable.

**Cloud Agent / Linux.** `doctor.ps1`, `run.ps1`, and `scripts/*_demo.ps1` stay
PowerShell (`pwsh` is fine). Reviewer media uses the bash helper
`.cursor/skills/verify-marque/review-evidence.sh` (PowerShell twin:
`review-evidence.ps1`). Windowed self-capture needs a real X display: honour
`$DISPLAY`, and if it is unset but `/tmp/.X11-unix/X1` exists the helper uses
`:1`. Headless Godot cannot produce reviewer pixels. Do not automate the desktop
mouse; the game still screenshots itself.

**Fresh checkout or worktree: warm the Godot caches once, before anything else.**
`client/.godot/` is gitignored, and without it headless Godot fails to *parse* any
script that names a global `class_name`, then cascades into a wall of unrelated
inference errors that look nothing like the real cause:

    godot --headless --path client --editor --quit

`run.ps1` performs this itself when `client/.godot/` is absent, and additionally runs
a headless import pass before launching two clients at once, because two Godot
processes importing simultaneously race over `.godot/` and the loser comes up with
missing assets.

The editor warm-up has one side effect: it generates `*.gd.uid` companion files in
`client/` for any script that lacks one. They are untracked litter from a
verification run, not part of your change — delete them rather than committing them
(`git status --short | Where-Object { $_ -match '\.uid$' }` finds them, and the
headless suites pass without them).

**Server.** Build it outside the repo tree and run it; `-addr 127.0.0.1:0` means the
kernel picks the port and two runs can never collide:

    cd server; go build -o $env:TEMP\marqued.exe ./cmd/marqued; cd ..
    & $env:TEMP\marqued.exe -addr 127.0.0.1:0

Readiness is the `server_started` GAMELOG line on stdout. It cannot appear before the
listener is bound, and it announces the port actually taken:

    GAMELOG {"addr":"127.0.0.1:52731","ev":"server_started","path":"/ws","t":0,"tick_ms":150,...}

The WebSocket URL is `ws://<addr>/ws`. Poll for the line; never sleep a guessed
interval. `-gamelog=false` silences the log and with it every server-side proof, so
leave it on.

**Client, scripted and windowed** (rendering needs a real desktop session):

    godot --path client --position 40,60 -- --server ws://127.0.0.1:52731/ws --shots C:\somewhere\a --click 0.30,0.72 --phase 1

Everything after the bare `--` is a user flag read by `client/scripts/main.gd`. The
client screenshots itself from inside the engine; nothing automates the desktop.

**Client, headless** (logic, physics, signals, scenes — no rendering server, no pixels):

    $env:MARQUE_WS_URL = "ws://127.0.0.1:52731/ws"
    godot --headless --path client --script res://tests/run_tests.gd --quit-after 1600

**Teardown:** stop the server with `Stop-Process -Id <pid> -Force`, using the PID you
started. Never kill by process name.

## Doctor

One read-only check that answers "is this checkout worth driving?":

    powershell -ExecutionPolicy Bypass -File .cursor/skills/verify-marque/doctor.ps1

`DOCTOR OK` means Go and Godot 4.7 answer on PATH and the repo has the server, the
client, and both canonical scripts where this skill expects them. It also fails closed
on windowed demos: every `scripts/*_demo.ps1`, every `client/scripts/*_demo.gd`, and
every `--*-shots` string literal in `client/scripts/main.gd` must appear in
`.cursor/skills/verify-marque/demo-allowlist.txt`. An unlisted file or flag fails
doctor. Helpers such as `scripts/marque-demo-lib.ps1`,
`client/scripts/demo_npc_capture.gd`, `review-evidence.sh`, and
`review-evidence.ps1` are not windowed demos and are not scanned. Doctor does
require those two review-evidence helpers to exist on disk. There is no
`.github/` workflow tree in this repo; **doctor is the gate**.
It warns — with the exact warm-up command — when `client/.godot/` is missing. Run it
first whenever anything looks off.

**Hard rule: do not mint a new windowed demo for quest (or other) content.** New
quest coverage extends the Go server and thin WebSocket / headless proof paths; it
does not add `*_demo.ps1`, `*_demo.gd`, or a new `--*-shots` flag. **ARM-290
exception:** when splitting an oversized allowlisted demo into bounded single-claim
units, add the new files/flags to `demo-allowlist.txt` in the same change and
fail-close the kitchen sink. Doctor enforces the allowlist; the skill text alone
is not enough.

## Drive

### The client's flag path (`client/scripts/main.gd`)

| Flag | Meaning |
|---|---|
| `--server <ws-url>` | Connect to this server. Without it the client runs offline. |
| `--shots <abs-prefix>` | Enter scripted demo mode; write `<prefix>_1.png` … `<prefix>_4.png`. **Absolute host path required**: two Godot processes share one `user://` and would overwrite each other's frames. |
| `--click fx,fy` | Where this client clicks the ground, as viewport fractions, e.g. `0.30,0.72`. |
| `--phase 1\|2` | Which of the two phases this client clicks in. Absent or 0: it never walks, only watches and captures. |
| `--pickup-shots <abs-prefix>` | Enter the contested-pickup demo mode (`pickup_demo.gd`); write `<prefix>_1.png` … `<prefix>_3.png`. **M1e.** Both clients run this with identical arguments; neither is told who wins. Absolute host path required, for `--shots`' reason. |
| `--drop-click fx,fy` | Where the winner of that contest clicks the ground before dropping, as viewport fractions. Required alongside `--pickup-shots`, and refused rather than defaulted if it will not parse. |
| `--equip-shots <abs-prefix>` | Enter the equip milestone demo mode (`equip_demo.gd`); write `<prefix>_1.png` … `<prefix>_3.png`. **M3d.** Single client; the demo starts marqued with `-join-kit sword`. Absolute host path required. |
| `--gather-craft-shots <abs-prefix>` | **Fail-closed** (ARM-287). `gather_craft_demo.gd` / `scripts/gather_craft_demo.ps1` exit non-zero; do not drive for proof. Use `--gather-error-shots` for live gather. |
| `--craft-cast-shots <abs-prefix>` | **Fail-closed** (ARM-290). Drive `--mine-smelt-craft-shots` / `--cast-bar-shots`. |
| `--mine-smelt-craft-shots <abs-prefix>` | Mine→smelt→craft sword demo (`mine_smelt_craft_demo.gd`). Single client; marqued `-admin`; client `/give`s miner+sticks. Absolute host path required. |
| `--cast-bar-shots <abs-prefix>` | Fireball cast-bar resolve + walk interrupt (`cast_bar_demo.gd`). Absolute host path required. |
| `--gather-error-shots <abs-prefix>` | Enter the refused-gather demo mode (`gather_error_demo.gd`); write `<prefix>_1.png` … `<prefix>_3.png`. **ARM-147.** One client; right-clicks the tree unarmed, reads the refusal, wears a ground-seeded lumberjack set, chops. Absolute host path required. |
| `--combat-shots <abs-prefix>` | **Fail-closed** (ARM-284). `combat_demo.gd` / `scripts/combat_demo.ps1` exit non-zero; do not drive for proof. Use `--dummy-attack` / `--heal-wounded-shots`. |
| `--combat-role attacker\|victim` | Legacy companion to `--combat-shots`. Same fail-closed rule; ignored by the stub. |
| `--dummy-cast <abs-prefix>` | Dummy cast demo (`dummy_cast_demo.gd`). Absolute host path required. |
| `--dummy-attack <abs-prefix>` | Hostile-dummy melee demo (`dummy_attack_demo.gd`). Absolute host path required. |
| `--wasd-shots <abs-prefix>` | WASD move demo (`wasd_demo.gd`). Absolute host path required. |
| `--arena-collision-shots <abs-prefix>` | Ring of Trials wall/ramp/jump demo (`arena_collision_demo.gd`). Absolute host path required. **M14g / ARM-259.** |
| `--tab-combat-shots <abs-prefix>` | **Fail-closed** (ARM-290). Drive `--wasd-shots` / `--dummy-cast` / `--dummy-attack` / `--heal-wounded-shots`. |
| `--heal-wounded-shots <abs-prefix>` | Heal raises wounded friendly dummy HP (`heal_wounded_demo.gd`). Absolute host path required. |
| `--quest-shots <abs-prefix>` | Quest demo (`quest_demo.gd`). Absolute host path required. |
| `--enemy-quest-shots <abs-prefix>` | **Fail-closed** (ARM-290). Drive `--enemy-party-shots` / `--enemy-midchase-shots` / `--enemy-quest-turnin-shots`. |
| `--enemy-quest-role leader\|member` | Legacy companion to `--enemy-quest-shots`. Same fail-closed rule; ignored by the stub. |
| `--enemy-party-shots <abs-prefix>` | Party + accept `slay_imps` (`enemy_party_demo.gd`). Requires `--enemy-party-role leader\|member`. Absolute host path required. |
| `--enemy-party-role leader\|member` | Which side of the enemy party demo this client plays. |
| `--enemy-midchase-shots <abs-prefix>` | Mid-chase Imp visibility (`enemy_midchase_demo.gd`). Absolute host path required. |
| `--enemy-quest-turnin-shots <abs-prefix>` | Camp kills + party credit + turn-in (`enemy_quest_turnin_demo.gd`). Requires `--enemy-quest-turnin-role leader\|member`. Absolute host path required. |
| `--enemy-quest-turnin-role leader\|member` | Which side of the turn-in demo this client plays. |
| `--screenshot [abs-path]` | No server needed: render `main.tscn`, save one frame, print its absolute path, quit. Optional absolute host path; omitted, writes `user://shot.png`. The single-client visual baseline and the screenshot half of reviewer evidence. |
| `--record-frames <abs-prefix>` | No server needed: after the same warmup, write `<prefix>_1.png` … `<prefix>_N.png` and print `REVIEW frame` / `REVIEW frames done`. Optional `--record-count N` (2–60, default 16) and `--record-interval-ms MS` (16–1000, default 100). Not a `--*-shots` demo; doctor does not allowlist it. Use for reviewer video / ordered frames, then stitch with `review-evidence.sh stitch`. |

Scripted demo mode waits for **two** players (`DEMO_MIN_PLAYERS` in `main.gd`), so a
lone `--shots` client times out after 20s and exits 1 by design; scripted windowed
sessions are two-client sessions. The click is a synthesised `InputEventMouseButton`
pushed at the viewport, so it travels the whole player path: picker → session →
socket → server.

### The generic harness

    powershell -ExecutionPolicy Bypass -File .cursor/skills/verify-marque/run.ps1

Optional: `-ClickA "0.30,0.72" -ClickB "0.70,0.72" -EvidenceDir <dir>`. Pass
`-ClickA ""` (or `-ClickB ""`) to make that client watch without ever walking.

It builds marqued, warms the caches, starts the server on a free port, runs client a
(clicks in phase 1) and client b (clicks in phase 2), tears everything down, and
leaves the evidence directory behind — the path is printed, defaulting under
`$env:TEMP\marque-verify\`.

**All three harnesses empty their output directory before they run**, so a reused
`-EvidenceDir` cannot leave stale `DEMO` logs, GAMELOG, or PNG artifacts from a prior
run. `run.ps1`'s default path is fresh every run, so this bites only a reused
`-EvidenceDir`; `two_client_demo.ps1`'s default is the fixed
`$env:TEMP\marque-two-client` and `contested_pickup_demo.ps1`'s the fixed
`$env:TEMP\marque-contested-pickup`, both reused forever. Each drops a
`.marque-evidence` marker into the directories it owns and **refuses to run into a
non-empty directory that lacks one** rather than deleting somebody else's files. So: do
not point any of them at a directory you care about, and do not treat files in an
evidence directory as belonging to the run you are reading unless that run's own output
printed them.

`VERIFY HARNESS OK` asserts only structure on the default proof layers: the server
announced itself (`server_started` GAMELOG), outlived the clients, and wrote nothing
to stderr; both clients joined (`DEMO joined`), printed `DEMO done`, and exited 0.
PNG self-captures may still land in the evidence directory as artifacts; **their
presence or byte size is not a harness pass** (ARM-289). **It deliberately asserts
nothing behavioural.** Your claim is proven by your own assertions against the
evidence files — DEMO + GAMELOG by default; named-pixel only when you name the
contract. A frozen server still earns `VERIFY HARNESS OK` on structure alone.

For the fixed M0 milestone scenario with its assertions already written, run
`scripts/two_client_demo.ps1` instead; this harness exists for every other scenario.

### What `scripts/two_client_demo.ps1` proves

Both layers, since M1g. Its client layer is
the pixels and the `DEMO pos` displacements; its server layer asserts, per player
id resolved from that client's `DEMO joined` line, a `client_connected`, at least
one non-zero GAMELOG `move` wish for each walker, `DEMO groundclick_ignored` /
`DEMO walkto` / `DEMO move_displacement`, and **zero** player `path_assigned` /
`move_to` for the run. It then ties the layers together: both clients' shot-4
`DEMO pos` for the phase-1 walker agree within 0.05 (server pose on both sides).
Watcher displacement proves the server moved — remotes follow pose only.
Soft PNG size / existence checks are not part of the pass (ARM-289).
Until M1g it asserted **nothing** about the server. All twenty-odd of its checks read
a client's stdout or a client's PNG, and it deleted the server's log at teardown, so
`game.World.step` losing its movement line earned `TWO CLIENT DEMO OK` with
displacements byte-identical to a healthy run. If you are reading a demo transcript
from before this section existed, it is evidence about pixels only.

### What `scripts/contested_pickup_demo.ps1` proves

The M1 milestone, on three layers. `features/contested-pickup.md` is the full recipe;
this is what the harness itself asserts and why the shape differs from the M0 demo's.

**The claim is server-side and no arrangement of pixels can carry it.** "Exactly one
client gets the item" is a fact about the server's store. Two clients that both drew an
empty patch of ground look identical whether the item went to one player, to both, or
to neither. So the load-bearing assertions are one `pickup_resolved` and one
`pickup_lost` for the same item id naming different players, two `pickup` intents from
two distinct players on the same tick, and no `pickup_rejected` or `pickup_no_room`.

**Approach and walk-away are wish+pose.** The harness fails closed on any
player `path_assigned` or `move_to`. The winner must log non-zero GAMELOG `move`
wishes and print `DEMO wish` / `DEMO walkaway_arrived`; drop `item_spawned`
coordinates must match that arrived pose (and stay clear of the origin / seed).

**It is the only thing in this repo that asserts `item_spawned`'s coordinates.** For
the seed, against what `-item` asked for; for the drop, against the winner's
`DEMO walkaway_arrived` pose, plus a floor on the distance from the origin and from
where the item was seeded — so a run whose coordinates were zeroed cannot pass by
having the walk also end at zero. A verifier logged those coordinates zeroed while
the store and the wire stayed truthful and all 93 Go tests stayed green; anything
that reads the log as ground truth, this harness included, was wrong with no way to
say so.

**There is no `item_despawn` event in the event log.** The despawn is a wire message
only (`items.go`, `w.broadcast(mnet.ItemDespawn...)`); `EvItemDespawned` does not
exist. Do not write a recipe that greps for it. The demo proves the despawn from
`pickup_resolved`, which causes it, and from both clients dropping the item body —
which a client does only on receiving that frame.

Sabotage-tested: `memStore.TakeGroundItem` was changed to leave the item on the ground,
so both contestants took it. The demo failed on ten assertions at once, led by "the
server resolved 2 pickup(s) of item 1, want exactly 1" and "the server recorded 0 lost
pickup(s)", and both clients reported holding an acorn.

### Raw protocol probes

For a wire-level claim the flag path cannot reach (malformed frames, retired
`move_to`, admin bus checks), use the in-repo thin helper
[`server/internal/wsprobe`](../../../server/internal/wsprobe) /
[`server/cmd/wsprobe`](../../../server/cmd/wsprobe) — see
[features/wsprobe-admin-move-to.md](./features/wsprobe-admin-move-to.md). Do not
reinvent ad-hoc sockets outside the repo for verify. Speak one-key JSON at a
running server, asserting on reply frames and on the GAMELOG. The headless suites
already prove the client's *handling* of `error`, `despawn`, and halt paths
against scripted frames; a probe is for the server's side of the same contract.

## Evidence

Everything a `run.ps1` drive can prove lands in its evidence directory:

| File | What it is |
|---|---|
| `server.stdout.ndjson` | The GAMELOG: the server's ground truth. One JSON object per line, keyed by tick `t`, greppable. |
| `server.stderr.log` | Empty on a healthy run. Anything here is a panic or a fatal. |
| `client-a.stdout.log`, `client-b.stdout.log` | The `DEMO` lines (grammar below), plus anything the client logged loudly. |
| `client-a.stderr.log`, `client-b.stderr.log` | **Where a client failure actually lands.** `push_error` and `printerr` go here, not to stdout. |
| `a_1.png` … `a_4.png`, `b_1.png` … `b_4.png` | Self-captures (artifacts). Not soft-pass proof: assert only via a named-pixel contract, or ignore them and prove with DEMO + GAMELOG. Shots 1–2 bracket phase 1 (a's walk), shots 3–4 bracket phase 2 (b's walk). |
| `.marque-evidence` | The harness's claim on the directory. Its presence is what lets the next run empty it. |

`scripts/two_client_demo.ps1` writes the same set, under its `-OutDir`, with the
same names.

**Read the stderr files first when a client failed.** The most diagnostic message in
this whole skill goes there and nowhere else: a run that produced `DEMO TIMEOUT: fewer
than 2 players after 20000ms` in a 50-byte `client-a.stderr.log`, while
`client-a.stdout.log` simply stopped after `session: connecting`. An agent reading only
stdout sees a client that trailed off and has to guess.

**That timeout cannot be the frozen-server sabotage this paragraph used to blame, and
nothing has established what it was.** `world.go` takes connections and tick steps in
two separate arms of one `select`, so a server that has stopped stepping still admits
players and still broadcasts their spawns; both clients reach two known ids and the join
wait in `main.gd` returns long before its 20-second deadline. Two independent runs of the
sabotage agree with the mechanism, the original writer's and M1j's verifier's, the latter
failing cleanly when the GAMELOG showed no player locomotion (no non-zero `move`
wishes) with both client stderr files empty and no timeout at all. What a frozen
server actually does is pass every client-layer assertion and lose on the event log,
which is the reason the GAMELOG layer exists. Load is the remaining explanation and
nobody has reproduced the timeout under it.

**GAMELOG vocabulary (M0 + wish+pose):** `server_started`, `server_stopping`,
`client_connected`, `client_disconnected`, `move`, `move_rejected`, `move_to_rejected`,
`intent_ignored`, `path_assigned` (NPC locomotion / patrol), `arrived` (NPC path
completion), `path_replayed`, `ticks_dropped`, `frame_dropped`. The constants live in
`server/internal/game/world.go`; M1 adds new `ev` values rather than changing these.
Player locomotion proofs use `move` + pose/`DEMO pos`, not player `path_assigned`.
`path_assigned` / `arrived` already follow the player/npc field split.

**`client_disconnected` carries a latched, cause-authoritative `reason` (M1f).** The reason
names why the connection died, never which component noticed: `closed` for a clean logout,
`slow_client`, `peer_gone`, `server_shutdown`, `protocol_error`. The first condemnation wins, so
a read error provoked by a client that was already dropped for being slow is still logged as
`slow_client`. An optional `detail` names the detector — `send_buffer_full`, `write_timeout`,
`read_error`, `write_error` — and is absent where only one detector could have fired. Read
`detail` to learn how a death was noticed; never branch on it, and never read it as the cause.
`server/internal/net/hub.go` (`Disconnect*` / `Detail*`) and `condemnation_test.go` encode the table.

**DEMO line grammar** (client stdout, written to be grepped):

    DEMO joined <player-id>
    DEMO groundclick <px> <py> <x> <z>
    DEMO clicked <px> <py>
    DEMO groundclick_ignored <x> <z>
    DEMO walkto <px> <py> <x> <z>
    DEMO shot <n> <abs-path>
    DEMO pos <shot-n> <player-id> <x> <z>
    DEMO npc <id> <kind> <x> <z> walking=<0|1> has_path=<0|1>
    DEMO anim <id> <clip|none>
    DEMO midchase
    DEMO done

`DEMO pos` reports every **avatar** the client drew in that frame, read from the
same avatars the renderer just drew. NPCs use `DEMO npc` / `DEMO anim` instead —
never overload `DEMO pos` with NPC bodies. `walking=1` means the NPC still has an
unfinished polyline (root motion), not that a walk clip is playing. `DEMO anim`
prints the AnimationPlayer's current clip, or `none` when missing/empty. Client
labels do not map to fixed player ids — the two clients race to connect — so
always resolve ids via `DEMO joined`. Shared dump helper:
`client/scripts/demo_npc_capture.gd`.

**Proof standards.**

- Exercise the real user path — a synthesised click through the picker — never an
  internal setter. There are no test-only endpoints here; do not add one for a proof.
- **Default:** assert DEMO + GAMELOG for the claim. Capture the action and the
  resulting state (e.g. GAMELOG `move` **and** `DEMO pos` displacement),
  not just a final screen.
- Assert both layers: what the client reported (`DEMO …`) and what the server
  believes (GAMELOG). Movement example: displacement between bracketing shots of at
  least 2.0 world units **and** non-zero GAMELOG `move` for that player id (watcher
  `DEMO pos` for two-client claims).
- **PNG only with a named-pixel contract.** Name the pixel fact that would be missing
  if the claim were false: the cast shadow, the second body, the still-camera quiet
  band, the frames that must differ where the walker crossed. File existence or
  `>4KB` is never enough.
- No mocks. There is no production boundary here that isolates an external system —
  both binaries are real or the run proves nothing.
- A comparison over zero input passes vacuously. Before trusting any "identical" or
  "no difference" verdict, assert the comparison consumed nonzero bytes; this
  skill's own proof run produced a false "sky band identical" from a
  silently-disposed bitmap whose band read back as zero bytes.

## Reviewer-facing evidence

This lane is for **humans reading the PR**, not for pass/fail. Run it after the
behavioural verify that already printed its marker. Attach the best 1–3 artifacts
so Arminas can open the GitHub PR and see the feature without launching the client.

**Decide the kind from the feature, then stop.**

| Kind | When | Capture |
|---|---|---|
| **Screenshot** | Static layout/chrome at rest: inventory hover popup *content*, recipe sheet open, highlight colors at rest, cursor/mode badge in one frame. | `--screenshot /abs/out.png`, or copy 1–2 PNGs from an existing allowlisted demo's evidence dir. |
| **Video / ordered frames** | Temporal UX: enter Use-mode → highlights appear → cancel clears; hover pop-in/out; preview cue on Use-hover; sheet dismiss; cast-bar appear/resolve. | `--record-frames /abs/prefix` (optional `--record-count`, `--record-interval-ms`), then `review-evidence.sh stitch --prefix … --mp4`. Keep clips to a few seconds. Prefer engine frames + ffmpeg over desktop recorders. Godot `--write-movie` is allowed if ffmpeg is missing; convert to mp4 before attach. |
| **None** | Pure logic/wire already covered by DEMO+GAMELOG / Go / headless. Heartbeat, rejected intents, `move_to` refuse, store contests. | Do not capture. Do not attach a decorative title-screen PNG. |

Prefer extending an existing allowlisted demo or these two flags over minting a
new `*_demo.ps1` / `*_demo.gd` / `--*-shots` flag. If you must add one of those,
update `demo-allowlist.txt` in the same change (ARM-290). `--record-frames` is
not a `--*-shots` flag; doctor does not allowlist it.

### Capture + attach path

Staging dir (not committed; emptied only by you): `$TMPDIR/marque-review-evidence`
on Linux, `$env:TEMP\marque-review-evidence` on Windows.

Linux / Cloud Agent (from repo root):

    bash .cursor/skills/verify-marque/review-evidence.sh capture-screenshot
    # writes $TMPDIR/marque-review-evidence/baseline.png (default staging)
    # After the PR exists:
    bash .cursor/skills/verify-marque/review-evidence.sh attach \
      --files "${TMPDIR:-/tmp}/marque-review-evidence/baseline.png" \
      --pr auto --kind screenshot \
      --caption "main.tscn baseline; HUD chrome at rest"

    bash .cursor/skills/verify-marque/review-evidence.sh capture-frames \
      --mp4 --attach --pr auto \
      --kind video --caption "Use-mode highlights then cancel"

Windows:

    powershell -ExecutionPolicy Bypass -File .cursor/skills/verify-marque/review-evidence.ps1 `
      capture-screenshot -Attach -Pr auto -Caption "main.tscn baseline"

`--attach` / `attach` runs `gh pr comment --attach`. GitHub renders PNG/JPEG/GIF
inline and plays MP4 in the comment. That is the preferred surface: reviewers see
the media on github.com without Cursor, and relative markdown in a PR *body*
resolves against the default branch, so committed files in the head branch do not
embed there unless you use a `blob/<head>/...?raw=true` URL.

Optional durable copy: commit at most those same 1–3 files under
`docs/review-evidence/<issue-or-slug>/` so the Files tab shows them. Do not dump
full demo evidence dirs. Label them reviewer media, not proof.

Markers: `REVIEW CAPTURE OK`, `REVIEW STITCH OK`, `REVIEW ATTACH OK` — last line
**and** exit 0, same rule as every other recipe. A missing output file fails the
helper because there is nothing to attach; that is not a named-pixel contract and
not a substitute for `DEMO done`.

Reuse demo PNGs when the visual claim already drove `scripts/*_demo.ps1`: copy
the informative frames out of `-OutDir` *before* the next harness run empties it,
then `attach`. Do not re-assert PNG byte size.

Feature files keep Atlas's four H2s. Put a one-line **Reviewer evidence:** note
in Driving or Gotchas where the change is visual. `features/README.md` has the
kind table.

## Headless-only claims

The suite runner (`client/tests/run_tests.gd`) owns the false-pass holes: it requires
every suite to run and assert, watchdogs the run at `WATCHDOG_FRAMES = 1250`, and
prints its `PASS:` line only from a completed report. **Any bound a runner enforces
must sit below the `--quit-after` it runs under** — `--quit-after` exits 0, so a
watchdog above it can never fire and is decorative. The server-backed suites skip
themselves when `MARQUE_WS_URL` is unset, so a green run with no `INTEROP RAN:` line
tested far less than it appears to. `scripts/interop_test.ps1` enforces all of this
and is the canonical full-stack pass. The suite count is the length of
`TREE_FREE_SUITES` plus `SCENE_SUITES` in `client/tests/run_tests.gd`, 15 at
`af818e3`; the assertion count grows with every unit, so run the suite for the current
number and report what you got rather than comparing against a figure written here.

## Cleanup

- `run.ps1` and both canonical scripts stop only the processes they started, by PID,
  and remove only their own scratch working directories.
- The evidence directory is never cleaned up *after* a run. Proof artifacts survive
  at the printed path; delete them yourself only after the claim is recorded.
  Reviewer-media staging (`marque-review-evidence`) is the same: the helper does
  not delete captures after attach.
- It is emptied at the *start* of the next run of that harness, so copy anything you
  intend to keep somewhere else before rerunning. A directory the harness did not
  write is refused rather than emptied.
- A crashed or interrupted run can strand a windowed client or the server; kill them
  by the PIDs from the harness output, never by image name — `godot.exe` may be the
  user's own editor.

## What this cannot do

- **No display, no pixels.** Windowed clients need a real desktop session; there is
  no virtual-display path here. Headless runs prove logic, never rendering. In
  display-less CI, only `interop_test.ps1`-style headless runs and Go tests exist.
  Reviewer media has the same constraint: no X/Wayland, no attachable pixels.
- **Behavioural proof is never media presence.** Reviewer screenshots and short
  clips (see *Reviewer-facing evidence*) let a human see the feature on the PR.
  They do not pass a claim. Named-pixel contracts remain the only pixel
  assertions. Do not treat a PNG, GIF, or MP4 as a substitute for DEMO lines or
  GAMELOG. Human aesthetic judgment is not an assertion.
- **`go test -race` needs a C toolchain on PATH first.** The LLVM-MinGW toolchain is
  installed but not on PATH by default. Put a C toolchain Go can use as `CC` on PATH,
  then from `server/`: `CGO_ENABLED=1 go test -race ./...`. This entry used to say no C
  compiler existed. That was true until 2026-09-02.
- **No desktop automation.** The game drives and screenshots itself; nothing moves
  the real mouse. What the flag path cannot reach, a raw protocol probe must.
  Do not drive reviewer video with a desktop screen recorder or computer-use
  mouse when `--screenshot` / `--record-frames` / an existing demo can shoot it.
- **One shared `user://`.** Anything two clients both write must go to absolute
  paths.
- **A starved display fails every visual assertion at once.** Each capture waits 15
  rendered frames; measured under load on this machine, one took about 4.4 seconds,
  longer than the walk window it brackets, so both frames of a phase showed the
  walker already far along and every displacement read wrong. Six client-side failures
  together with a healthy GAMELOG is that, not a broken build. Confirm it from the
  server's clock — the walkers' first non-zero `move` wishes should sit about one
  phase gap apart — and free the display before believing anything visual.

## The still-camera control

This section replaces the former *Known flake* entry on the sky band, which described a
control that no longer exists.

`two_client_demo.ps1`'s still-camera control is the top quarter of the frame. Until
ARM-183 it asserted byte-exactness there, on the premise that the region held only sky.
ARM-171 put a 7.265 u tree in the world, canopy pixels landed in the band, and lit
alpha-scissored foliage is not bit-exact across two GPU frames, so the control failed on
every run at that head.

It now asserts the band is **quiet**, not identical. At most 0.5% of the band's pixels
may differ, and no channel of any pixel by more than 2 of 255. Both bounds must hold.
The walking pair is put through the same test and must **fail** it, so every green run
prints both sides of the boundary and proves the tolerance still discriminates.

Measured across nine idle runs at `0a19b2d` and four on `main`, 1280x720, band 230,400 px:

| Pair | Differing pixels | Max channel delta |
|---|---|---|
| Still camera, canopy in the band | 8, 0.0035%, every run | 1 |
| Still camera, no canopy in the band | 0 | 0 |
| Camera that walked | 98,000–153,000, 43%–66% | 155 |

The tolerance sits near the geometric middle of that four-order-of-magnitude gap.

**The sky-band waiver is retired. A band failure is a finding.** The old advice was to
rerun on an idle machine and treat a lone band failure as noise; that advice now points
at the only control this demo has for a camera that moved when it should have been
still. The noise it used to excuse is inside the tolerance. `SKY-BAND FLAKE CANDIDATE`
is no longer printed by anything.

A band failure names its own numbers. Read them: a handful of pixels off by 1 that
somehow cleared the bound is a different problem from half the band off by 155, which is
a camera that moved.

## Feature map

`features/README.md` indexes what is verifiable, feature by feature, each with its
driving recipe and the observable end state that proves it. A proof that drives one
convenient entry point is incomplete when the map lists others. Keep the map honest
with `/maintain-verification-skill` as the app grows.
