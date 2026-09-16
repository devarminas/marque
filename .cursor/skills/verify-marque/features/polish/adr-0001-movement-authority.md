# Polish ADR 0001 — Movement authority

Server owns player pose; client sends wish/jump inputs only; player polylines are
retired. Presentation of walk/camera/jump is the prop mock; authority and
illegal samples are Go / live wire.

## Sub-features

- `inputs-not-pose` — `move` bodies with pose-fact keys refuse `illegal_sample`
- `server-integrates` — wish steers at WalkSpeed; pose broadcasts carry `x,y,z`
- `no-player-path` — approach / WASD do not assign player `path` (ARM-239)
- `presentation` — walk anim + camera follow (mock prop; not wire)

## How to get to it (user POV)

Hold WASD on a live client: avatar moves under server poses. Left-click bare
ground does not start a polyline walk.

## Driving it with Go + prop mock + existing WASD demo

**Authority / illegal sample (Go, required for wire claims):**

```bash
cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestClientCannotAuthorPositionViaMove|TestApproachSteerBroadcastsPoseEachStep|TestLastIntentWinsMoveOverApproach|TestWireStateIncludesY'
cd server && CGO_ENABLED=1 go test -race ./internal/net/ -run 'TestDecodeMoveIllegalSample|TestDecodeMoveToRetired'
```

**No player path on approach (net harness):**

```bash
cd server && CGO_ENABLED=1 go test -race ./internal/net/ -run 'TestPickup|Replay'
```

Or full: `CGO_ENABLED=1 go test -race ./...` from `server/`.

**Presentation (mock, no marqued):** see
[props/player-character.md](./props/player-character.md).

**Live wish+pose (optional, existing demo only):**

```powershell
powershell -File scripts/wasd_demo.ps1
```

Marker `WASD DEMO OK`. Do not add a new windowed demo for this ADR.

## Gotchas

- Mock cannot falsify `illegal_sample` or "no player path on the wire." Those
  stay Go / GAMELOG.
- Player `move_to` / `path` recipes under [move-to-walk](../move-to-walk.md) are
  retired; do not revive them here.
