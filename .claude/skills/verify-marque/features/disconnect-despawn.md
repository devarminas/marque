# Leaving the world

When a client's connection ends, everyone else sees that player vanish: the server
broadcasts `despawn` and logs `client_disconnected` with one `reason`, whichever the
hub reported. A client whose own socket died freezes the world it has and logs
loudly — M0
has no reconnect, so it neither clears the world nor pretends.

## Sub-features

- `leave-despawn` — survivors' worlds drop the leaver's body.
- `leave-reason` — the GAMELOG carries a `reason`, one of the six the server
  actually defines (see Gotchas).
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
- **Assert the reasons the server defines, not the ones `PROTOCOL.md` names.** The
  `Disconnect*` constants in `server/internal/net/hub.go` are the whole list:

  | Constant | Logged `reason` | When |
  |---|---|---|
  | `DisconnectClosed` | `closed` | the peer closed the connection |
  | `DisconnectReadError` | `read_error` | the connection failed while reading |
  | `DisconnectWriteError` | `write_error` | the connection failed while writing |
  | `DisconnectSlow` | `send_buffer_full` | the client could not keep up |
  | `DisconnectShutdown` | `server_shutdown` | the server is going away |
  | `DisconnectProtocol` | `protocol_error` | the frame was uninterpretable |

  A scripted client that quits on its own schedule lands on `read_error`, and that
  is what every healthy `run.ps1` and `two_client_demo.ps1` run logs today.

  `PROTOCOL.md`'s M1 section names `peer_gone` and `slow_client` instead. **Neither
  string exists anywhere under `server/`.** They belong to a recorded decision — the
  cause is authoritative over the detector, and the first condemnation latches —
  that unit M1f will implement and nothing implements yet. An agent asserting the
  protocol's names against today's server reports a defect that is not one, or
  worse, "fixes" the server to match a document describing the future.
- Nothing latches yet, and `client_disconnected` carries only `player` and `reason`.
  There is no `detail` field on it to assert or to avoid; `detail` exists on
  `move_to_rejected` and nowhere else.
- M0's ordinary traffic is too sparse to fill the send queue; a stalled client dies
  by timeout minutes later. Do not wait for it in a bounded run.
