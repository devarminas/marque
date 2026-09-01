# Rejected and malformed intents

The server validates every intent against its own state and trusts nothing a client
says. A rejected intent earns the sender one `error` frame and one log line, and is
never broadcast; a malformed frame is answered and the connection closed. The player
experience is simply that nothing moves — the `error` frame exists so that is
distinguishable from packet loss.

## Sub-features

- `reject-oob` — a `move_to` outside `[-128, 128]²` is rejected, not clamped:
  `error` with `re":"move_to"`, GAMELOG `move_to_rejected`, no broadcast.
- `reject-degenerate` — clicking where you already stand (stationary) yields
  `"already there"` and no path.
- `reject-malformed` — a frame with zero or several top-level keys, or a non-JSON
  or binary frame, is a protocol error: `error` then close.
- `ignore-unknown` — an unknown top-level key is logged loudly and ignored
  (compatibility rule 1), on both ends.

## How to get to it (user POV)

- An ordinary player cannot reach most of these: the visible ground lies inside the
  bounds, so they arrive only from a broken or malicious client. `reject-degenerate`
  is the one a player can trigger, by clicking their own feet while standing still.

## Driving it with a raw protocol probe

Preconditions:

- A running marqued from SKILL.md's Launch, its URL in hand; `PROTOCOL.md` open.

- **Client-side handling (already covered headless).** `powershell
  -ExecutionPolicy Bypass -File scripts/interop_test.ps1` (marker `INTEROP OK`)
  includes the suites that feed scripted `error`, halt-path, and unknown-key frames
  into the real decode path and assert the client logs-and-drops rather than
  closing.
- **Server-side rejection, live.** Write a throwaway WebSocket client in a scratch
  directory outside the repo (Go with its own `go.mod`; the module proxy is
  reachable). Send `{"move_to":{"x":1000.0,"z":0.0}}`. Assert the reply frame is
  `{"error":{"re":"move_to",...}}`, the GAMELOG gains `move_to_rejected`, and a
  second connected probe receives **no** `path` broadcast for it.
- **Malformed frame.** Send `{"a":1,"b":2}` (two top-level keys). Assert an `error`
  frame arrives and the socket then closes, and that a well-formed probe on another
  connection is undisturbed.
- **Degenerate click.** After an `arrived`, resend the same `move_to`. Assert
  `"already there"` in the `error` and that no `path` reached the other probe.

## Gotchas

- `error.re` is absent, not null, when the frame could not be attributed; read it
  with a default.
- The close-on-malformed rule is the server's only. The client must never close on a
  bad server frame; it logs and drops the frame. Do not "fix" either side to match
  the other.
- Rejection is the designed behaviour for unreachable clicks going forward
  (`NOTES.md`), so `move_to_rejected` in a log is not by itself a defect.
- JSON cannot carry NaN/Infinity literals; the live hazard is a large finite float
  like `1e30`, which is exactly what `reject-oob` exists to stop.
