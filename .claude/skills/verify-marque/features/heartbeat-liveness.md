# Server liveness: heartbeats and the dead-socket abandon

Since M2c the client never sits on a dead socket. The server broadcasts a `tick`
heartbeat every `heartbeat_ticks` ticks (10 on this build); the client re-arms a
liveness window of `3 × heartbeat_ticks × tick_ms` on every one it receives, and when
a window runs out it logs loudly, reports the expiry, and abandons the socket — with
**no close frame**, because the transport is already presumed dead. What follows is the
leave story, not a new one: the server suspends the player for the grace, and the
client goes on to reconnect as itself.

## Sub-features

- `liveness-arm` — `welcome.heartbeat_ticks` arms the window; a `heartbeat_ticks`
  that is absent or unusable reads as 0, which is liveness off (the pre-M2c client,
  which waits forever).
- `liveness-tick` — each received `tick` re-anchors the clock and re-arms the window;
  a clock correction is printed to stdout as
  `session: clock corrected by %+d tick(s) at heartbeat <t>` (one line per correction,
  not one per heartbeat).
- `liveness-abandon` — a silent server for a whole window produces one loud
  `push_error` line naming the window, then the socket is abandoned with no close
  frame; the server therefore sees `peer_gone`/`read_error`, not `closed`.
- `liveness-catch-liar` — a server that sends one heartbeat and then none is caught
  within three intervals of the join (the window opens at the join, not at the first
  heartbeat).

## How to get to it (user POV)

- The player sees nothing while things are healthy. When the server stops answering,
  the client logs that it is abandoning, freezes its last world, and starts
  reconnecting with backoff — the same "the server went away" experience as any other
  dead socket, reached now without waiting for a TCP timeout.

## Driving it with scripts/interop_test.ps1

Preconditions:

- `DOCTOR OK`; the headless path is the canonical one — driving a real liveness
  expiry windowed means stopping the server by PID and waiting out the window by
  hand, which `disconnect-despawn.md`'s freeze recipe already covers from the other
  end.

- **Run the headless pass.** `powershell -ExecutionPolicy Bypass -File
  scripts/interop_test.ps1`. Marker: `INTEROP OK`, and the suite-count line in the
  tail must name the current suite count (15 as of this revision). Its heartbeat
  suites feed scripted frames at an instanced `main.tscn`, so they need no server;
  the interop and wiring suites need `MARQUE_WS_URL`, which the script provides.
- **Wire layer.** The tick-protocol suite asserts `welcome` carries `heartbeat_ticks`
  as an int, that an absent or non-integer one reads as 0 without costing the
  welcome, and that `abandon()` emits `disconnected` immediately and stays silent on
  a second call.
- **Behaviour layer.** The heartbeat suite and its edges suite assert the armed
  window, the re-arm on each tick, the loud log at expiry, and that a window is
  claimed exactly once.
- **Live, end to end.** `test_interop.gd` abandons peer X without a close frame and
  then resumes it against a real marqued, so the GAMELOG gains a `peer_gone`
  disconnect, `player_suspended`, and `player_resumed` for the same id. Assert that
  triple from `server.stdout.ndjson` if you want the server's side of an abandon
  without building anything.

## Gotchas

- **A heartbeating server is never silent at the event-log layer.** There is no
  `tick` event in the GAMELOG (one line per heartbeat would bury the log); liveness
  on the server side is only visible as the *absence* of any client reaction plus
  the client's own stdout. The GAMELOG still proves the abandon's consequences:
  `client_disconnected` with `reason=peer_gone`, then the suspend/resume pair.
- **`abandon` is not a logout.** It sends no close frame, so the server must classify
  it as `peer_gone`/`read_error` and suspend the player. A run whose abandoned peer
  was retired at once is a defect in the classification, not a faster cleanup.
- **The abandon's stdout line is the only client-side proof of *why*.**
  `push_error` goes to stderr (`client-*.stderr.log`), the `server_unresponsive`
  report and the reconnect schedule go to stdout. Read both tails.
- **Do not shrink the window to make a test faster.** The suites cap
  `Engine.max_fps` for their own duration instead (NOTES.md, "Godot authoring
  traps"); a shortened window is a different feature.
