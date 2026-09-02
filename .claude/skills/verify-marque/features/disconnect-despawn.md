# Leaving the world

When a client's connection ends, everyone else sees that player vanish: the server
broadcasts `despawn` and logs `client_disconnected` with one `reason`, whichever the
hub reported. A client whose own socket died freezes the world it has and logs
loudly — M0
has no reconnect, so it neither clears the world nor pretends.

## Sub-features

- `leave-despawn` — survivors' worlds drop the leaver's body.
- `leave-reason` — the GAMELOG carries a `reason`, one of the five causes the server
  defines, plus an optional `detail` naming the detector (see Gotchas).
- `leave-freeze` — a client that lost the server keeps its last world, frozen, and
  logs loudly rather than clearing.

## How to get to it (user POV)

- Close the client window, or the process dies, or the connection drops.

## Driving it with run.ps1

Preconditions:

- `DOCTOR OK`; a desktop session.

- **Reasons on record.** Any default `run.ps1` drive ends with both clients quitting
  after `DEMO done`; assert `server.stdout.ndjson` gains one `client_disconnected`
  per player id, each with a `reason` field, after that client's last activity.
  Marker for the run itself: `VERIFY HARNESS OK`.
- **Survivor sees the despawn, headless.** The wiring suite under `powershell
  -ExecutionPolicy Bypass -File scripts/interop_test.ps1` (marker `INTEROP OK`)
  asserts a `despawn` frame removes exactly the body it names and that an unknown id
  changes nothing.
- **Survivor sees the despawn, on screen.** The scripted demo path cannot kill one
  client mid-run, so drive it manually per SKILL.md's Launch: start the server and
  two windowed clients, then stop client b by its PID. Assert client a's log gains a
  loud despawn line for b's id, and a self-`--screenshot`-style capture or the next
  scripted run's frames show one capsule where two stood. Report this path as
  manual-only if you skip it; do not claim it via the headless half.
- **Freeze, not clear.** Stop the *server* by PID while a client is connected.
  Assert the client logs the dead socket loudly and its world stays drawn (the
  other capsule remains on screen), rather than emptying.

## Gotchas

- The demo flag path always runs both phases and quits on its own schedule; killing
  one of its clients mid-run makes the survivor's own run fail its capture contract.
  Expect exit 1 from the survivor and judge the claim on the logs and frames, not on
  its exit code.
- **`reason` is a cause and `detail` is a detector. Assert the first; read the second
  and do not branch on it.** Since M1f the `Disconnect*` and `Detail*` constants in
  `server/internal/net/hub.go` are the whole list, and they agree with
  `PROTOCOL.md`'s M1 section:

  | Logged `reason` | Logged `detail` | When |
  |---|---|---|
  | `closed` | absent | the peer sent a close frame; not a failure |
  | `slow_client` | `send_buffer_full` | the 64-frame send queue was already full |
  | `slow_client` | `write_timeout` | one write outlived the 5s write timeout |
  | `peer_gone` | `read_error` | a read failed on anything but a close frame |
  | `peer_gone` | `write_error` | a write failed, but not for want of time |
  | `server_shutdown` | absent | the server is going away |
  | `protocol_error` | absent | the frame was uninterpretable |

  `detail` is absent, not empty, wherever only one detector could have fired. A test
  that asserts the key exists on every line is wrong.

  **The pairing for a quitting Godot client is inherited, not freshly observed.**
  Before M1f a client that quit on its own schedule logged `read_error`, which was
  the old name for "the read failed and it was not a close frame" — so the client
  does not close cleanly. That same failure now logs `reason: "peer_gone"` with
  `detail: "read_error"`. The translation is mechanical and nobody has re-run a live
  client to confirm it. If you drive `run.ps1`, confirm it and say so.
- **The first condemnation latches, so a `reason` is not always the last thing that
  went wrong.** A client dropped for being slow has its socket torn down, and the
  read pump then sees that teardown as a read error. The line still says
  `slow_client`, because a consequence must not overwrite a cause. Do not read a
  `slow_client` line as evidence that nothing else failed afterwards; something
  almost certainly did.
- M0's ordinary traffic is too sparse to fill the send queue; a stalled client dies
  by timeout minutes later. Do not wait for it in a bounded run.
