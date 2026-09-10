# 0003. Movement wire names

## Status

Accepted (M13c / ARM-235). Settles the JSON names sketched in `docs/adr/0001-movement-authority.md`.

## Decision

1. **Uplink.** Client→server locomotion stays under top-level key `move`. Body: required finite floats `dx` and `dz` (ground-plane wish in world axes); optional `jump` bool (accepted and ignored until jump ships); optional `seq` under existing rules.
2. **Illegal samples.** Before applying a `move` body, refuse if any pose-fact key is present: `x`, `z`, `y`, `pos`, `position`, `pose`, `path`, `velocity`, `vx`, `vz`, `vy`. Non-finite `dx`/`dz` refuse the same way. RejectReason `illegal_sample`; `Error.Re` is `move`; connection kept; body not applied.
3. **`move_to`.** Player `move_to` is refused at decode with `illegal_sample`. It never becomes a game intent. Connection kept.
4. **Downlink.** Server→client player locomotion is `pose` `{id,tick,x,y,z}`. `y` is always present (always `0` until jump). Broadcast on integrate and halt. `welcome` / `spawn` / `PlayerState` carry the same `x,y,z`. Idle reanchor at least every `PoseIdleEveryTicks = 25` is required by ADR 0001 and lands with the client apply PR (silence-based net harness cannot absorb continuous idle poses yet).
5. **Player `path`.** Not used for WASD/halt. Approach AI and NPCs may still use `path` until later units retire player approach polylines.

## Consequences

- Exact names live here and in `server/internal/net` tests. Do not revive `PROTOCOL.md`.
- Client apply/predict of `pose` is a stacked PR.
