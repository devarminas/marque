---
name: verify-marque
description: Drive Project Marque the way a player does — the real marqued Go server plus real Godot 4.7 clients — and prove behavioural claims from self-captured screenshots, the clients' DEMO lines, and the server's NDJSON event log. Use whenever a claim about client or server behaviour needs evidence stronger than a passing unit test.
---

# Verify Marque

Project Marque is a Go WebSocket server (`server/`, binary `marqued`) and a Godot 4.7
Forward+ desktop client (`client/`) speaking one-key JSON messages (`PROTOCOL.md`).
This skill is how an agent launches the real stack, drives it like a player, and reads
back what actually happened. It was written against M0 (connect, click to move, see
each other walk); `features/README.md` is the maintained map of what is verifiable.

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
| `run.ps1` (this skill) | `VERIFY HARNESS OK` |
| marqued readiness | a `GAMELOG` line with `"ev":"server_started"` |
| each scripted client | `DEMO done` on its stdout |

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

`VERIFY HARNESS OK` asserts only structure: the server announced itself, outlived the
clients, and wrote nothing to stderr; both clients joined, printed `DEMO done`,
exited 0, and wrote four >4KB frames each. **It deliberately asserts nothing
behavioural.** Your claim is proven by your own assertions against the evidence
files. For the fixed M0 milestone scenario with its assertions already written, run
`scripts/two_client_demo.ps1` instead; this harness exists for every other scenario.

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
| `a_1.png` … `a_4.png`, `b_1.png` … `b_4.png` | Self-captures. Shots 1–2 bracket phase 1 (a's walk), shots 3–4 bracket phase 2 (b's walk). |

**GAMELOG vocabulary (M0):** `server_started`, `server_stopping`, `client_connected`,
`client_disconnected` (with a latched, cause-authoritative `reason`), `move_to`,
`move_to_rejected`, `intent_ignored`, `path_assigned`, `arrived`, `path_replayed`,
`ticks_dropped`, `frame_dropped`. The constants live in
`server/internal/game/world.go`; M1 adds new `ev` values rather than changing these.

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
and is the canonical full-stack pass: on a healthy checkout it reports 321 assertions
across 6 suites.

## Cleanup

- `run.ps1` and both canonical scripts stop only the processes they started, by PID,
  and remove only their own scratch working directories.
- The evidence directory is never part of cleanup. Proof artifacts survive the run at
  the printed path; delete them yourself only after the claim is recorded.
- A crashed or interrupted run can strand a windowed client or the server; kill them
  by the PIDs from the harness output, never by image name — `godot.exe` may be the
  user's own editor.

## What this cannot do

- **No display, no pixels.** Windowed clients need a real desktop session; there is
  no virtual-display path here. Headless runs prove logic, never rendering. In
  display-less CI, only `interop_test.ps1`-style headless runs and Go tests exist.
- **A captured PNG is the whole visual story.** No video, no motion capture, no human
  aesthetic judgment — only assertions computable from the files.
- **`go test -race` is unavailable.** No C compiler on this machine, so cgo cannot
  build. Do not emit a recipe containing `-race` and do not install a toolchain; this
  is a recorded program-level gap (`STANDING-ORDERS.md`, Verified tooling).
- **No desktop automation.** The game drives and screenshots itself; nothing moves
  the real mouse. What the flag path cannot reach, a raw protocol probe must.
- **One shared `user://`.** Anything two clients both write must go to absolute
  paths.

## Known flake

`two_client_demo.ps1`'s still-camera control asserts byte-exactness over the top
quarter of a GPU-rendered frame. One flip was observed on a fully static frame across
eighteen measured windows, explicable only by render nondeterminism. It fails in the
safe direction, never a false pass. If the demo fails on **only** "the background is
not a control" with a still fraction near zero, rerun before investigating.

## Feature map

`features/README.md` indexes what is verifiable, feature by feature, each with its
driving recipe and the observable end state that proves it. A proof that drives one
convenient entry point is incomplete when the map lists others. Keep the map honest
with `/maintain-verification-skill` as the app grows.
