# Follow-ups

Real fine-tuning parked for when the human is available. Numbers, pacing, feel, art direction.
Nothing here blocks a milestone. Nothing here is a bug.

Each entry names what to tune, where the value lives, and what "wrong" would feel like, so the
human can judge it in one sitting instead of rediscovering the context.

## Camera feel

- **Orbit sensitivity, pitch clamp, zoom range.** Placeholder values chosen to be usable, not
  good. Wrong feels like the camera fighting you when you try to look at something.
- **Follow damping.** How hard the camera chases the player. Zero damping is rigid and slightly
  nauseating, too much is soupy and hides where you are.
- **Default pitch and distance on first spawn.** This is the first frame a player ever sees, so
  it deserves an opinion rather than a default.

## Movement feel

- **Walk speed.** Server-side, in world units per second, sent in the `speed` field of the path
  message. RuneScape's walk is deliberate and unhurried on purpose. We have not decided whether
  Marque matches that or moves faster.
- **Click-to-first-step latency.** One server round trip by design (see NOTES.md, Movement). If
  it reads as sluggish, the documented escape hatch is cosmetic client-side pathing that
  reconciles when the server path lands. Do not build that until it actually feels bad.
- **Interpolation between ticks.** At a 150ms tick, the client is interpolating most of the
  time. Whether it lerps position or also smooths turning is a feel call.

## Tick rate

- **150ms is decided and deliberately revisitable exactly once**, when there is enough gameplay
  to feel it. That moment is after M1, when there is an inventory action to time. Not before.
  Revisiting it earlier is re-litigating a settled decision with no new evidence.

## Art direction

- The palette in NOTES.md is diagnostic, not aesthetic. Magenta-for-missing and flat unlit
  capsules exist so an agent can read a screenshot. None of it is a look.
- **When the human wants a look**, that is a separate pass over materials and lighting, and it
  should not touch the semantic colors used by the debug palette.
