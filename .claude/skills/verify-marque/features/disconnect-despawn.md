# Leaving the world

When a client's connection ends the server logs `client_disconnected` with one `reason`,
whichever the hub reported. **Whether everyone else sees that player vanish now depends on
that reason.** A clean close removes the body at once. A socket that simply died leaves the
body standing for sixty seconds first, so that the same player can come back to it. A client
whose own socket died freezes the world it has and logs loudly: the shipped client has no
reconnect, so it neither clears the world nor pretends.

**Since M2a the timing is the trap in this whole feature.** The shipped Godot client dies
abruptly rather than closing, so the despawn a human is waiting for is a minute away, and an
agent that watches for ten seconds and files a defect is wrong. Read the grace gotcha below
before driving any of this.

## Sub-features

- `leave-despawn` — survivors' worlds drop the leaver's body: at once for a clean close,
  after the grace for anything else.
- `leave-reason` — the GAMELOG carries a `reason`, one of the six causes the server
  defines, plus an optional `detail` naming the detector (see Gotchas).
- `leave-suspend` — an abrupt death logs `player_suspended` and broadcasts nothing at all;
  the body keeps walking, keeps its inventory, and finishes a pending pickup.
- `leave-expire` — the grace runs out, `player_expired` is logged, and the despawn goes out
  then.
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

  **Budget sixty seconds for it, and check the server log first.** Killing a PID is an
  abrupt death, so the server suspends the player and broadcasts nothing. What you should
  see immediately is `client_disconnected` with `peer_gone` and then
  `player_suspended` carrying an `expires_tick`; b's capsule stays on screen, standing
  where it was, for the whole grace. `player_expired` is the line that immediately precedes
  the despawn. Assert the sequence rather than only the despawn: a capture taken in between
  showing two capsules is the feature working, and reading it as a failure is the mistake
  this bullet exists to prevent.

  **The 400-tick grace is not a constant to trust from here.** `marqued` reports it as
  `resume_grace` on its `server_started` line; read it from the run.
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
  | `refused` | absent | a resume for a player who is still connected (**never appears in the log**, see below) |

  `detail` is absent, not empty, wherever only one detector could have fired. A test
  that asserts the key exists on every line is wrong.
- **`reason` now decides whether a despawn happens at all. M2a.** The two halves of the
  table split, and the split is the feature:

  | `reason` | What the world does |
  |---|---|
  | `closed`, `protocol_error`, `server_shutdown` | retire at once: `despawn`, inventory deleted, id retired |
  | `peer_gone`, `slow_client` | suspend for the grace: no `despawn`, body and inventory kept |
  | `refused` | nothing; the connection was never admitted |

  So `client_disconnected` no longer implies a `despawn`, and counting one to predict the
  other is now wrong. The event that predicts a despawn is `player_expired`.
- **`refused` is latched but never logged, and that is deliberate.** A connection presenting
  a session token whose player is still connected is turned away at the door: it gets
  `{"error":{"msg":"session is still connected"}}`, the socket closes, and the only record
  is one `resume_refused` line carrying `remote`. There is no `client_connected` and no
  `client_disconnected` for it, because the world never admitted it. **Do not file the
  missing pair as a defect.**
- **Session tokens are never in the log, by rule.** `welcome.session` is on the wire and
  nowhere in the NDJSON. If you find a 32-hex string in an event, that is a real defect;
  `TestNoSessionTokenIsLoggedAnywhere` is what normally catches it.

  **A quitting Godot client logs `peer_gone`/`read_error`. Observed live, M1f.**
  `two_client_demo.ps1` against `4c09af7`, two real windowed clients, exit 0, final
  line `TWO CLIENT DEMO OK`:

      GAMELOG {"detail":"read_error","ev":"client_disconnected","player":2,"reason":"peer_gone","t":70}
      GAMELOG {"detail":"read_error","ev":"client_disconnected","player":1,"reason":"peer_gone","t":71}

  The cause is `peer_gone` because `main.gd`'s quit path is `get_tree().quit()` and
  the file contains no `net.close()` at all: the socket just dies, no close frame is
  ever sent, and the read pump has nothing to tell it the peer meant to leave.

  **Since M2a that fact decides the timing of everything on screen.** The shipped client
  falls in the suspend half of the table above, so quitting it leaves its capsule standing
  in every other client's world for the whole grace. That is correct behaviour and not a
  leak.

  **Predicted and not yet observed**, because M2a is a server-only unit that ran neither
  demo: a demo run should now end with `player_suspended` for each client and no closing
  `despawn`, since both quit within a second of each other and the process exits long before
  a sixty-second grace could run out. Check it the next time either demo is driven, and
  correct this paragraph rather than trusting it.

  **The interop suite logs `closed` for what looks like the same event, and that is
  not a contradiction. Read this before filing a defect.** `interop_test.ps1`
  produces seven `client_disconnected` events and every one says `closed`, because
  `test_interop.gd` calls `net.close()` explicitly at `:236` and `:731`. Its clients
  send a close frame; the shipped client does not. **Both results are correct, and
  they differ because the clients behave differently, not because the server is
  inconsistent.** An agent who checks only the suite concludes the real client closes
  cleanly, which is false — that inference was drawn and caught during M1f. To learn
  what the shipped client does, drive the demo, not the suite.

  **M2a widened that gap rather than closing it.** `closed` retires at once and `peer_gone`
  suspends, so the interop suite's peers still vanish immediately while the shipped client's
  do not. An agent generalising from `INTEROP OK` to "despawns are prompt" is now wrong about
  behaviour and not merely about a log field.
- **The first condemnation latches, so a `reason` is not always the last thing that
  went wrong.** A client dropped for being slow has its socket torn down, and the
  read pump then sees that teardown as a read error. The line still says
  `slow_client`, because a consequence must not overwrite a cause. Do not read a
  `slow_client` line as evidence that nothing else failed afterwards; something
  almost certainly did.
- M0's ordinary traffic is too sparse to fill the send queue; a stalled client dies
  by timeout minutes later. Do not wait for it in a bounded run.
