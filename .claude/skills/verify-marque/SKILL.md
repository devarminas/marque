---
name: verify-marque
description: Drive Project Marque the way a player does — the real marqued Go server plus real Godot 4.7 clients — and prove behavioural claims from self-captured screenshots, the clients' DEMO lines, and the server's NDJSON event log. Use whenever a claim about client or server behaviour needs evidence stronger than a passing unit test.
---

# Verify Marque

Project Marque is a Go WebSocket server (`server/`, binary `marqued`) and a Godot 4.7
Forward+ desktop client (`client/`) speaking one-key JSON messages (`PROTOCOL.md`).
This skill is how an agent launches the real stack, drives it like a player, and reads
back what actually happened. It was written against M0 (connect, click to move, see
each other walk) and now covers M1 (items, pickup, drop, the contested-pickup demo,
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
| `run.ps1` (this skill) | `VERIFY HARNESS OK` |
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

**Two evidence layers, and a behavioural claim usually needs both.** The client walks
polylines by itself: the server sends waypoints once and never per-tick positions, so
after a `path` broadcast the pixels and `DEMO pos` lines prove what the *client
drew*, while the GAMELOG proves what the *server believes*. A server whose tick loop
stopped advancing players would still produce moving pixels on every client, because
each client interpolates the path it was handed. "The player moved" is proven by
client-side displacement (`DEMO pos`) **and** the server's `arrived` event, not by
either alone.

**A screenshot assertion must name the specific thing that would be missing.** "The
screenshot shows lighting" was passed in this repo by a build whose sun pointed at
the sky, lit by ambient alone; "the capsule casts a shadow on the ground" would have
failed it instantly. Assert the shadow, the second body, the displacement between two
named frames — never the vibe.

## Launch

All commands run from the repo root. Go 1.27 and Godot 4.7 (`godot`) are on PATH;
every script here also honours `$env:GODOT` as the Godot executable.

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
    godot --headless --path client --script res://tests/run_tests.gd --quit-after 900

**Teardown:** stop the server with `Stop-Process -Id <pid> -Force`, using the PID you
started. Never kill by process name.

## Doctor

One read-only check that answers "is this checkout worth driving?":

    powershell -ExecutionPolicy Bypass -File .claude/skills/verify-marque/doctor.ps1

`DOCTOR OK` means Go and Godot 4.7 answer on PATH and the repo has the server, the
client, and both canonical scripts where this skill expects them. It warns — with the
exact warm-up command — when `client/.godot/` is missing. Run it first whenever
anything looks off.

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
| `--screenshot` | No server needed: render `main.tscn`, save one frame to `user://shot.png`, print its absolute path, quit. The single-client visual baseline. |

Scripted demo mode waits for **two** players (`DEMO_MIN_PLAYERS` in `main.gd`), so a
lone `--shots` client times out after 20s and exits 1 by design; scripted windowed
sessions are two-client sessions. The click is a synthesised `InputEventMouseButton`
pushed at the viewport, so it travels the whole player path: picker → session →
socket → server.

### The generic harness

    powershell -ExecutionPolicy Bypass -File .claude/skills/verify-marque/run.ps1

Optional: `-ClickA "0.30,0.72" -ClickB "0.70,0.72" -EvidenceDir <dir>`. Pass
`-ClickA ""` (or `-ClickB ""`) to make that client watch without ever walking.

It builds marqued, warms the caches, starts the server on a free port, runs client a
(clicks in phase 1) and client b (clicks in phase 2), tears everything down, and
leaves the evidence directory behind — the path is printed, defaulting under
`$env:TEMP\marque-verify\`.

**All three harnesses empty their output directory before they run**, because the only
checks any of them makes on a frame are that it exists and is over 4KB, and a stale PNG
from a previous run satisfies both. `run.ps1`'s default path is fresh every run, so
this bites only a reused `-EvidenceDir`; `two_client_demo.ps1`'s default is the fixed
`$env:TEMP\marque-two-client` and `contested_pickup_demo.ps1`'s the fixed
`$env:TEMP\marque-contested-pickup`, both reused forever. Each drops a
`.marque-evidence` marker into the directories it owns and **refuses to run into a
non-empty directory that lacks one** rather than deleting somebody else's files. So: do
not point any of them at a directory you care about, and do not treat files in an
evidence directory as belonging to the run you are reading unless that run's own output
printed them.

`VERIFY HARNESS OK` asserts only structure: the server announced itself, outlived the
clients, and wrote nothing to stderr; both clients joined, printed `DEMO done`,
exited 0, and wrote four >4KB frames each. **It deliberately asserts nothing
behavioural.** Your claim is proven by your own assertions against the evidence
files — and per the two-layer rule above, a movement claim needs the GAMELOG as well
as the pixels, because a frozen server still earns `VERIFY HARNESS OK`.

For the fixed M0 milestone scenario with its assertions already written, run
`scripts/two_client_demo.ps1` instead; this harness exists for every other scenario.

### What `scripts/two_client_demo.ps1` proves

Both layers, since M1g. Its client layer is the pixels and the `DEMO pos`
displacements; its server layer asserts, per player id resolved from that client's
`DEMO joined` line, a `client_connected`, a `move_to`, a `path_assigned` spanning at
least 2.0 units, and an **`arrived` after that path's `start_tick` whose coordinates
match its endpoint** — the one event a server that hands out paths and never moves
anybody cannot produce. It then ties the layers together: the phase-1 walker's
`arrived` point must be within 0.05 units of where both clients drew that body in
shot 4.

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
two distinct players, and no `pickup_rejected` or `pickup_no_room`.

**It also asserts every walk is plausible, which the M0 demo does not.** That demo
proves the server *finished* a walk — it matches an `arrived` against the endpoint of
the path it assigned — and a tick loop whose per-tick distance is 1000.0 crosses the
whole polyline in one tick and produces a perfectly formed `arrived`. This one checks
`arrived.t - start_tick` against `ceil(span / (WalkSpeed * TickDuration))` within two
ticks. Healthy figures on this machine: 16 ticks for a 7.071-unit walk, 13 for a
5.567-unit one, both exactly the ideal. That closes the open half of unit M1j at the
layer that depends on it.

**It is the only thing in this repo that asserts `item_spawned`'s coordinates.** For
the seed, against what `-item` asked for; for the drop, against where the dropper's
`arrived` says it stood, plus a floor on the distance from the origin and from where
the item was seeded — so a run whose coordinates were zeroed cannot pass by having the
walk also end at zero. A verifier logged those coordinates zeroed while the store and
the wire stayed truthful and all 93 Go tests stayed green; anything that reads the log
as ground truth, this harness included, was wrong with no way to say so.

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

For a wire-level claim the flag path cannot reach (malformed frames, out-of-bounds
intents), write a throwaway WebSocket client in a scratch directory **outside the
repo** (Go with its own `go.mod` works; the module proxy is reachable) and speak
`PROTOCOL.md` at a running server, asserting on the reply frames and on the GAMELOG.
The headless suites already prove the client's *handling* of `error`, `despawn`, and
halt paths against scripted frames; a probe is for the server's side of the same
contract.

## Evidence

Everything a `run.ps1` drive can prove lands in its evidence directory:

| File | What it is |
|---|---|
| `server.stdout.ndjson` | The GAMELOG: the server's ground truth. One JSON object per line, keyed by tick `t`, greppable. |
| `server.stderr.log` | Empty on a healthy run. Anything here is a panic or a fatal. |
| `client-a.stdout.log`, `client-b.stdout.log` | The `DEMO` lines (grammar below), plus anything the client logged loudly. |
| `client-a.stderr.log`, `client-b.stderr.log` | **Where a client failure actually lands.** `push_error` and `printerr` go here, not to stdout. |
| `a_1.png` … `a_4.png`, `b_1.png` … `b_4.png` | Self-captures. Shots 1–2 bracket phase 1 (a's walk), shots 3–4 bracket phase 2 (b's walk). |
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
failing cleanly on `0 arrived event(s)` with both client stderr files empty and no
timeout at all. What a frozen server actually does is pass every client-layer assertion
and lose on the event log, which is the reason the GAMELOG layer exists. Load is the
remaining explanation and nobody has reproduced the timeout under it.

**GAMELOG vocabulary (M0):** `server_started`, `server_stopping`, `client_connected`,
`client_disconnected`, `move_to`, `move_to_rejected`, `intent_ignored`, `path_assigned`,
`arrived`, `path_replayed`, `ticks_dropped`, `frame_dropped`. The constants live in
`server/internal/game/world.go`; M1 adds new `ev` values rather than changing these.

**`client_disconnected` carries a latched, cause-authoritative `reason` (M1f).** The reason
names why the connection died, never which component noticed: `closed` for a clean logout,
`slow_client`, `peer_gone`, `server_shutdown`, `protocol_error`. The first condemnation wins, so
a read error provoked by a client that was already dropped for being slow is still logged as
`slow_client`. An optional `detail` names the detector — `send_buffer_full`, `write_timeout`,
`read_error`, `write_error` — and is absent where only one detector could have fired. Read
`detail` to learn how a death was noticed; never branch on it, and never read it as the cause.
`PROTOCOL.md`, "Which reason is authoritative", has the full table.

**DEMO line grammar** (client stdout, written to be grepped):

    DEMO joined <player-id>
    DEMO clicked <px> <py>
    DEMO shot <n> <abs-path>
    DEMO pos <shot-n> <player-id> <x> <z>
    DEMO done

`DEMO pos` reports every body the client drew in that frame, read from the same
avatars the renderer just drew. Client labels do not map to fixed player ids — the
two clients race to connect — so always resolve ids via `DEMO joined`.

**Proof standards.**

- Exercise the real user path — a synthesised click through the picker — never an
  internal setter. There are no test-only endpoints here; do not add one for a proof.
- Capture the action and the resulting state: the GAMELOG `move_to` **and** the
  displacement it caused, not just a final screen.
- Assert both layers: what the client drew (`DEMO pos`, pixels) and what the server
  believes (GAMELOG). Movement example: displacement between bracketing shots of at
  least 2.0 world units **and** an `arrived` event for that player id.
- Name the pixel fact that would be missing if the claim were false: the cast shadow,
  the second body, the frames that must differ where the walker crossed.
- No mocks. There is no production boundary here that isolates an external system —
  both binaries are real or the run proves nothing.
- A comparison over zero input passes vacuously. Before trusting any "identical" or
  "no difference" verdict, assert the comparison consumed nonzero bytes; this
  skill's own proof run produced a false "sky band identical" from a
  silently-disposed bitmap whose band read back as zero bytes.

## Headless-only claims

The suite runner (`client/tests/run_tests.gd`) owns the false-pass holes: it requires
every suite to run and assert, watchdogs the run at `WATCHDOG_FRAMES = 850`, and
prints its `PASS:` line only from a completed report. **Any bound a runner enforces
must sit below the `--quit-after` it runs under** — `--quit-after` exits 0, so a
watchdog above it can never fire and is decorative. The server-backed suites skip
themselves when `MARQUE_WS_URL` is unset, so a green run with no `INTEROP RAN:` line
tested far less than it appears to. `scripts/interop_test.ps1` enforces all of this
and is the canonical full-stack pass. The suite count is the length of
`TREE_FREE_SUITES` plus `SCENE_SUITES` in `client/tests/run_tests.gd`, 13 at
`cf8d862`; the assertion count grows with every unit, so run the suite for the current
number and report what you got rather than comparing against a figure written here.

## Cleanup

- `run.ps1` and both canonical scripts stop only the processes they started, by PID,
  and remove only their own scratch working directories.
- The evidence directory is never cleaned up *after* a run. Proof artifacts survive
  at the printed path; delete them yourself only after the claim is recorded.
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
- **A captured PNG is the whole visual story.** No video, no motion capture, no human
  aesthetic judgment — only assertions computable from the files.
- **`go test -race` needs the PATH export first.** The LLVM-MinGW toolchain is
  installed but not on PATH by default; `STANDING-ORDERS.md`, *Verified tooling*, has
  the export line and the recipe (`CGO_ENABLED=1 go test -race ./...` from `server/`).
  This entry used to say no C compiler existed. That was true until 2026-09-02.
- **No desktop automation.** The game drives and screenshots itself; nothing moves
  the real mouse. What the flag path cannot reach, a raw protocol probe must.
- **One shared `user://`.** Anything two clients both write must go to absolute
  paths.
- **A starved display fails every visual assertion at once.** Each capture waits 15
  rendered frames; measured under load on this machine, one took about 4.4 seconds,
  longer than the 2.07-second walk it brackets, so both frames of a phase showed the
  walker already arrived and every displacement read 0. Six client-side failures
  together with a healthy GAMELOG is that, not a broken build. Confirm it from the
  server's clock — the two `move_to` events sit ~23 ticks apart on a healthy run and
  sat 81 apart here — and free the display before believing anything visual.

## Known flake

`two_client_demo.ps1`'s still-camera control is the sky-band check. It asserts
byte-exactness over the top quarter of a GPU-rendered frame. Failures cluster under
GPU load right after heavy suites. `DEMO pos` and path geometry can match a green
merge-base while the sky band still flips. The control fails in the safe direction,
never a false pass.

If the demo fails on **only** "the background is not a control" with a still
fraction near zero, use the steps below before you call a product regression.
`two_client_demo.ps1` prints `SKY-BAND FLAKE CANDIDATE` on that shape and names
the idle rerun and the geometry comparison.

1. Compare `DEMO pos` and path geometry to a green merge-base or a prior idle pass.
   Matching geometry is not a walk regression.
2. Run the next `two_client_demo.ps1` on an idle machine, with no other Godot work
   in flight.
3. Two consecutive sky-band failures under load are still this flake. Call a
   product regression only if the idle control also fails the sky band, or if
   geometry differs from the green base.

Measured shape of the flake: two consecutive sky-band failures immediately after
heavy suites, merge-base geometry identical, three later idle passes green.

## Feature map

`features/README.md` indexes what is verifiable, feature by feature, each with its
driving recipe and the observable end state that proves it. A proof that drives one
convenient entry point is incomplete when the map lists others. Keep the map honest
with `/maintain-verification-skill` as the app grows.
