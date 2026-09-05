# Rejected and malformed intents

The server validates every intent against its own state and trusts nothing a client
says. A rejected intent earns the sender one `error` frame and one log line, and is
never broadcast; a malformed frame is answered, and closed as well when the frame was
binary or had the wrong key count (a merely not-JSON text frame is answered and the
connection kept). The player
experience is simply that nothing moves — the `error` frame exists so that is
distinguishable from packet loss.

## Sub-features

- `reject-oob` — a `move_to` outside `[-128, 128]²` is rejected, not clamped:
  `error` with `"re":"move_to"`, GAMELOG `move_to_rejected`, no broadcast.
- `reject-degenerate` — clicking where you already stand (stationary) yields
  `"already there"` and no path.
- `reject-malformed` — a frame with zero or several top-level keys, or a binary
  frame, is a protocol error: `error` then close.
- `reject-nonjson` — a text frame that is not JSON, or JSON that is not an object
  (array, number, string), earns one `error` (`re` absent) and the connection is
  **kept**: only binary frames and key-count violations close.
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
- **Not-JSON text frame.** Send `not json`. Assert one `error` frame with no `re`
  and that the socket **stays** open — a well-formed `move_to` on the same
  connection still earns its `path`. This is `malformed_json`, disposition
  reply-only; the close is reserved for binary frames and key-count violations.
- **Degenerate click.** After an `arrived`, resend the same `move_to`. Assert
  `"already there"` in the `error` and that no `path` reached the other probe.

## Gotchas

- **There is no event named `protocol_error` in the GAMELOG.** An unattributable
  rejection (protocol error, binary frame) logs under the event name
  `move_to_rejected` — `rejectionEvent("")` maps an empty `re` there — carrying
  `"reason":"protocol_error"` (or `malformed_json`, or `binary_frame`) as a *field*
  and no `re`. The `protocol_error` you will also see in a `client_disconnected` is
  the close reason, a different field on a different event.
- **Newer intents bring their own rejections through the same door.** `pickup`,
  `drop`, `equip`, and `unequip` refusals log as `pickup_rejected`, `drop_rejected`,
  `equip_rejected`, `unequip_rejected`; a duplicate `seq` logs `intent_duplicate`
  with `re`, `seq`, and `last_seq` and is answered with silence. Equip onto an
  occupied worn slot is not a rejection at all: it swaps, logging a `displaced`
  field.
- `error.re` is absent, not null, when the frame could not be attributed; read it
  with a default.
- The close-on-malformed rule is the server's only. The client must never close on a
  bad server frame; it logs and drops the frame. Do not "fix" either side to match
  the other.
- Rejection is the designed behaviour for unreachable clicks going forward
  (`NOTES.md`), so `move_to_rejected` in a log is not by itself a defect.
- JSON cannot carry NaN/Infinity literals; the live hazard is a large finite float
  like `1e30`, which is exactly what `reject-oob` exists to stop.
