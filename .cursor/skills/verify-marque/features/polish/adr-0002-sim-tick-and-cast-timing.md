# Polish ADR 0002 — Sim tick and cast timing

One simulation clock at 40 ms (25 Hz). Cast grace and ability tick counts are
wall-clock retuned for that period. No client presentation claim; mock cannot
falsify tick law.

## Sub-features

- `tick-40ms` — `TickDuration = 40ms`; `welcome.tick_ms` matches
- `cast-grace-320ms` — `CastGraceTicks = 8` (320 ms at 40 ms)
- `heartbeat-period` — `HeartbeatEveryTicks = 10` unchanged in this ADR

## How to get to it (user POV)

Connect; `welcome.tick_ms` is 40. Cast interrupt feel matches ~320 ms grace.

## Driving it with Go

```bash
cd server && CGO_ENABLED=1 go test -race ./internal/game/ -run 'TestFireballWalkInterruptsOutsideGrace|TestFireballGraceSurvivesWalk|TestPath'
```

`server/internal/game/world.go` locks `TickDuration = 40 * time.Millisecond` and
`CastGraceTicks = 8`. Full suite: `CGO_ENABLED=1 go test -race ./...`.

No live demo and no prop mock for this ADR — clock law is server-owned.

## Gotchas

- Do not invent a windowed demo that sleeps wall-clock to "prove" 40 ms.
- Heartbeat wall-clock retune is ARM-242; this ADR only keeps the tick count.
