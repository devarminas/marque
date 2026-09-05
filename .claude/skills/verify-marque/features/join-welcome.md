# Joining the world

Starting the client with a server URL is the whole login: the connection is accepted,
the server sends `welcome` with this player's id and every player in the world, and
the client draws one Knight avatar per player — its own included — on the checkered
ground.

## Sub-features

- `join-connect` — a client connects and learns its own id from `welcome`.
- `join-see-world` — every listed player is drawn as a body, self included.
- `join-broadcast` — players already present see the newcomer appear (`spawn`).
- `join-join-kit` — the join kit is seeded and restated: the GAMELOG gains
  `join_seeded`, and the newcomer receives `inventory` and `equipment` frames as
  part of the join step, before it sends any intent.
- `join-late-paths` — a late joiner sees mid-walk players moving, via re-anchored
  path replays, not frozen at a stale position.

## How to get to it (user POV)

- Launch the client with `--server <ws-url>` after the `--` separator. There is no
  login screen, account, or button; identity is the connection — and since M2, the
  resume token the first `welcome` hands out (`welcome.session`) is how a dropped
  connection returns as the same player. The resume path itself is documented in
  [disconnect-despawn](./disconnect-despawn.md) and
  [heartbeat-liveness](./heartbeat-liveness.md).

## Driving it with run.ps1

Preconditions:

- `DOCTOR OK`; a desktop session; no flags needed beyond defaults.

- **Join two players.** Run
  `powershell -ExecutionPolicy Bypass -File .claude/skills/verify-marque/run.ps1`.
  Marker: `VERIFY HARNESS OK`.
- **Own id learned.** Each client log has one `DEMO joined <id>` line; the two ids
  are 1 and 2 in some order.
- **Server agrees.** `server.stdout.ndjson` has one `client_connected` event per id,
  before any other event naming that player. Right after each one sit that player's
  `join_seeded` and the `inventory`/`equipment` join step — expected lines, not
  anomalies.
- **Both drawn, both screens.** Every `DEMO pos <shot>` group in both client logs
  lists exactly two player ids — each client draws itself and the other, in all four
  shots.
- **Pixels.** In `a_1.png`, name what must be there: two Knight avatars on the
  checkered ground, each with a cast shadow. (The avatars were blue capsules once;
  they are the kaykit Knight mesh now.) Two bodies at the origin overlap at
  spawn; the demo path delays its first capture until after the first click, so the
  frame shows two separated bodies.
- **Late-join half.** `join-late-paths` needs a player mid-walk when another
  connects; the scripted demo path joins both before anyone walks, so it cannot
  reach this. It is proven headless by the wiring suite's welcome/replay assertions
  under `scripts/interop_test.ps1` (marker `INTEROP OK`), or by a manual launch:
  start the server and client a per SKILL.md's Launch, click, and start client b
  during the walk; b's `path_replayed`-driven avatar must be moving in b's frames.

## Gotchas

- Ids race. Client a is not reliably player 1; always read `DEMO joined`.
- A lone scripted client exits 1 after 20s by design (`DEMO_MIN_PLAYERS = 2`); that
  timeout is not a connection failure.
- `welcome` includes the joining player itself; asserting "one other body" undercounts.
- On a resume (a reconnect presenting `welcome.session`) the world gets
  `player_resumed`, **no** `client_connected` and **no** `spawn` — the second
  `welcome` alone rebuilds the client's view. Counting a fresh `client_connected` per
  welcome is wrong on any run where a client reconnected.
