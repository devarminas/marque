# 0008. Hostile overhead proximity

## Status

Accepted (Enemy combat v1 / ARM-264).

## Context

Hostile NPCs need an overhead name and HP readout that appears when the local player is near, without replacing the target-frame HUD (ARM-263). Clicking that readout must select the same target as clicking the body capsule. Server `hp` / `max_hp` (and optional `name` from ARM-268) are the only facts shown.

## Decision

1. **Proximity radius.** Overhead name + HP for a hostile NPC are shown when the horizontal (XZ) distance from the local player to the NPC is at most **12.0** world units. Beyond that distance the overhead chrome and its pick collider are hidden.
2. **Who.** Every hostile in range, not only the current target. Friendly and neutral overhead HP stay always-on when HP is known; they do not use this proximity gate.
3. **Facts.** Label text comes from the session HP cache and `NpcDummy.display_name`. Missing name is an empty string; the HP line still shows.
4. **Targeting.** Scene-authored `OverheadClick` (physics layer 4, same as `ClickBody`) is enabled only while the overhead is shown. `GroundPicker` resolves it to the parent NPC the same way as the body capsule.
5. **Coexistence.** This does not implement or replace the target-frame HUD.

## Consequences

- Tunable only by changing this ADR and the matching client constant (`NpcDummy.OVERHEAD_PROXIMITY`).
- Imp camp (~14 u from village origin) does not show overheads until the player walks into range.

## Non-goals

- Target-frame HUD (ARM-263).
- Client-invented names or HP.
- Player-vs-player overhead chrome.
