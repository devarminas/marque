# Polish ADR 0003 — Movement wire names

Uplink `move` with `dx`/`dz` (+ optional `jump`); downlink player `pose`; player
`move_to` refused; player `path` retired. Presentation stays on the prop mock.

## Sub-features

- `move-body` — decode accepts finite `dx`/`dz`; optional `jump`
- `illegal-sample` — pose-fact keys and non-finite wish refuse at decode
- `move-to-retired` — player `move_to` never becomes a game intent
- `pose-downlink` — server broadcasts `pose` `{id,tick,x,y,z}`

## How to get to it (user POV)

WASD sends `move` samples; the client applies `pose`. There is no click-to-path.

## Driving it with Go (+ optional WASD demo)

```bash
cd server && CGO_ENABLED=1 go test -race ./internal/net/ -run 'TestDecodeMove$|TestDecodeMoveWithJump|TestDecodeMoveIllegalSample|TestDecodeMoveToRetired|TestLargeFiniteWishDecodesCleanly'
cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestWireStateIncludesY|TestApproachSteerBroadcastsPoseEachStep'
```

Live (existing only): `powershell -File scripts/wasd_demo.ps1` → `WASD DEMO OK`
and no player `path_assigned` in GAMELOG.

Presentation of walk/idle under a pose stream:
[props/player-character.md](./props/player-character.md) (mock).

## Gotchas

- Idle pose reanchor (`PoseIdleEveryTicks`) may still be skipped in Go until the
  silence harness can absorb it; see `TestMoveIdlePoseKeepalive`.
- Do not revive `PROTOCOL.md`. Names live in ADR 0003 and these tests.
