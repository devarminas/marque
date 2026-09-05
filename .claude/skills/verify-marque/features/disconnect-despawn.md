# Leaving the world

When a client's connection ends the server logs `client_disconnected` with one `reason`,
whichever the hub reported. **Whether everyone else sees that player vanish now depends on
that reason.** A clean close removes the body at once. A socket that simply died leaves the
body standing for sixty seconds first, so that the same player can come back to it. A client
whose own socket died freezes the world it has, logs loudly, and reconnects: it presents
the last `welcome.session` on the next URL and rebuilds from the second `welcome`. It does
not clear the world between attempts.

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
- `leave-freeze` — a client that lost the server keeps its last world, frozen, logs
  loudly, and reconnects. Freeze ends on a successful resume. A close frame is
  logout and does not reconnect.

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
  two windowed clients, then stop client b by its PID. **The survivor prints
  nothing when a known player despawns** (`session.gd` logs only unknown-id
  despawns), so there is no "despawn line" to assert; a scripted survivor also
  quits seconds after its last capture, long before a 60-second grace can expire.
  What this path proves live is the grace itself: b's avatar stays drawn on a's
  screen for the whole grace — a capture taken in the middle showing two avatars
  is the feature working — while the log sequence
  `client_disconnected`/`peer_gone` → `player_suspended` (`expires_tick` ≈
  `resume_grace` ticks ahead) → `player_expired` proves the timing. **The despawn
  itself is never logged** — `retire` broadcasts the `despawn` frame and writes
  no GAMELOG event, exactly like `item_despawn` — so `player_expired` is the
  log's last word, stamped at the tick the frame went out. That the survivor's
  world drops the body on the `despawn` *frame* is the wiring suite's headless
  assertion; the on-screen vanish at expiry needs a client still connected past
  the grace, and no scripted flag path stays connected that long (`--shots`
  clients quit seconds after their last capture), so drive it with a manually
  launched idle client or accept the headless half. Report the manual
  path as manual-only if you skip it; do not claim it via the headless half.

  **Budget sixty seconds for it, and check the server log first.** Killing a PID is an
  abrupt death, so the server suspends the player and broadcasts nothing. What you should
  see immediately is `client_disconnected` with `peer_gone` and then
  `player_suspended` carrying an `expires_tick`; b's avatar stays on screen, standing
  where it was, for the whole grace. `player_expired` is the log's final word on that
  player — the despawn frame it coincides with is wire-only (see above). Assert the sequence rather than only the despawn: a capture taken in between
  showing two avatars is the feature working, and reading it as a failure is the mistake
  this bullet exists to prevent.

  **The 400-tick grace is not a constant to trust from here.** `marqued` reports it as
  `resume_grace` on its `server_started` line; read it from the run.
- **Freeze, then reconnect.** Stop the *server* by PID while a client is connected.
  Assert the client logs the dead socket loudly, its world stays drawn (the
  other avatar remains on screen), and it begins reconnect attempts with backoff
  rather than emptying. Then start the server again on the same URL and assert
  the client reconnects — but **on a fresh server process it does not come back
  as itself**: the session store is in memory, the old token is unknown
  (`resume_unknown` in the GAMELOG), and the client joins as a new player with a
  new id. The token's promise is the grace window, not a restart. Coming back as
  the same player is the same-process path — reconnect before the grace expires —
  which the interop suite's abandon-and-resume test proves headlessly (`INTEROP OK`
  gains a `peer_gone` disconnect, `player_suspended`, then `player_resumed` for
  one id). A clean close still does not reconnect.

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
  falls in the suspend half of the table above, so quitting it leaves its avatar standing
  in every other client's world for the whole grace. That is correct behaviour and not a
  leak.

  **Observed on both demos at `27c602d`, by M2a's first verifier.** A demo run ends with
  `client_disconnected` carrying `reason=peer_gone` and `detail=read_error`, then one
  `player_suspended` per player, and then nothing: **zero `despawn` and zero
  `player_expired`**, because both clients quit within a second of each other and the process
  exits long before a sixty-second grace can run out.

      two_client_demo.ps1       player_suspended  t:79   expires_tick:479
      contested_pickup_demo.ps1 player_suspended  t:125  expires_tick:525

  So a demo's log ending with bodies still in the world is the expected shape now, and an
  agent grepping a demo transcript for a closing `despawn` will not find one. This paragraph
  was written as a prediction by the unit that shipped the change, which ran neither demo,
  and is promoted here to an observation.

  **The interop suite mostly logs `closed` for what looks like the same event, and
  that is not a contradiction. Read this before filing a defect.** Most of
  `interop_test.ps1`'s `client_disconnected` events say `closed`, because
  `test_interop.gd` calls `net.close()` explicitly at `:268`, `:891`, and `:1005`.
  Its clients send a close frame; the shipped client does not. Both results are
  correct, and they differ because the clients behave differently, not because the
  server is inconsistent. An agent who checks only the suite concludes the real
  client closes cleanly, which is false — that inference was drawn and caught
  during M1f. To learn what the shipped client does, drive the demo, not the suite.

  **Since M2c the suite also abandons.** Its abandon-and-resume test drops peer X
  with `net.abandon()` (`:928`) — no close frame, the shipped client's own
  liveness path — so the suite now also produces a `peer_gone`/`read_error`
  disconnect with `player_suspended` and `player_resumed` for the same id. "Every
  disconnect in an `INTEROP OK` transcript says `closed`" was true once and is no
  longer; do not treat the suite's `peer_gone` as a defect.

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
