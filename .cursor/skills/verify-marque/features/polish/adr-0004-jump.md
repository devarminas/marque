# Polish ADR 0004 — Jump

Grounded jump edge sets `JumpSpeed`; gravity integrates `y`; mid-air jump is
`illegal_sample`. Server ballistic is Go; avatar height presentation is the prop
mock.

## Sub-features

- `jump-impulse` — grounded `jump: true` sets `vy = JumpSpeed`
- `ballistic-land` — gravity lands at `y = 0`, `vy = 0`
- `mid-air-refuse` — airborne jump refused; wish on that sample may still apply
- `jump-present` — client `present_at` height lifts the avatar (mock)

## How to get to it (user POV)

Press jump while grounded; the avatar rises and lands. Jump mid-air does nothing
authoritative.

## Driving it with Go + prop mock

```bash
cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestJumpStartsVerticalMotion|TestJumpWhileWalkingKeepsSteer|TestJumpLandsOnGround|TestMidAirJumpRefused|TestJumpCancelsPendingAttack'
```

**Presentation (mock, no marqued):**
[props/player-character.md](./props/player-character.md) jump height asserts.

No new windowed jump demo.

## Gotchas

- Constants `JumpSpeed = 5`, `Gravity = 20` are ADR law; changing them needs the
  ADR amended.
- Mock proves pixels/pose presentation only; mid-air refuse is Go.
