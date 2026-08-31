# Follow-ups

Real fine-tuning parked for when the human is available. Numbers, pacing, feel, art direction.
Nothing here blocks a milestone. Nothing here is a bug.

Each entry names what to tune, where the value lives, and what "wrong" would feel like, so the
human can judge it in one sitting instead of rediscovering the context.

## Camera feel

Shipped values, all `@export` on `CameraRig` in `client/scripts/camera_rig.gd` and editable in
the inspector on the `CameraRig` node of `client/scenes/main.tscn`. Every one was picked to be
usable, not good.

| Name | Value | What wrong feels like |
|---|---|---|
| `orbit_degrees_per_pixel` | `0.35` | The camera fights you when you try to look at something. |
| `zoom_step` | `1.5` | Wheel notches too coarse, or too slow to matter. |
| `follow_damping` | `12.0` | Rigid and slightly nauseating high, soupy and disorienting low. |
| `pitch_min_degrees` | `-80.0` | Near top-down. Legal, probably not wanted. |
| `pitch_max_degrees` | `-12.0` | Nearly level. The ground fills two pixels. |
| `distance_min` | `4.0` | Clipping into the player capsule. |
| `distance_max` | `32.0` | The player is a speck. |
| `default_yaw_degrees` | `30.0` | The first frame a player ever sees. |
| `default_pitch_degrees` | `-35.0` | Same. |
| `default_distance` | `14.0` | Same. |

## Movement feel

- **Walk speed, currently `3.0` world units per second** in `game.WalkSpeed`, broadcast in the
  `speed` field of every path message. RuneScape's walk is deliberate and unhurried on purpose.
  We have not decided whether Marque matches that or moves faster. Changing it is one constant.
- **`MinPathLength`, currently `1e-3` world units.** How near a click has to be to your feet
  before the server says "you are already there" instead of walking you. Wrong feels like small
  positional adjustments being silently swallowed.
- **Send buffer, currently `64` frames per connection.** How far a lagging client may fall
  behind before the server drops it. Wrong feels like players on poor connections being kicked
  during busy moments. This is a real tradeoff and not just a number: the buffer exists so a
  slow client can never block the tick loop.
- **Spawn point, currently the origin for everyone.** Fine for M0's two capsules, visibly wrong
  the first time five people connect and stack inside each other. There is no collision in M0,
  so nothing prevents it.

## What a first playtest will ask about

Found by M0e, the unit that first rendered two real players at once.

- **Everyone spawns at the origin, so two fresh clients are literally inside each other.**
  Already parked under Movement feel as a number, but it now has a concrete consequence: the
  milestone screenshot had to be re-timed to happen after somebody walked, because a frame taken
  at join time photographs two coincident capsules as one. It is the first thing a human will
  notice.
- **The local player is visually identical to everyone else.** RuneScape distinguishes you by
  name colour and a minimap dot. Marque has neither, so there is currently no way to tell which
  capsule is you except by clicking and watching what moves.
- **Nothing is drawn at the clicked point.** So a rejected click, a click on your own feet, and
  a dropped frame all look identical to the player, which is nothing happening. The server's
  `error` reply already reaches the client and currently becomes a log warning. This is the
  cheapest large improvement in the list.
- **`follow_damping` at 12.0 visibly trails at the start of a walk** in the demo captures. It
  might be right. It needs someone watching it move rather than looking at a still.

## Scale cliffs, not tuning

Not feel, but parked here for the same reason: real, unreachable today, and expensive to
discover the hard way.

- **A joining client is dropped at the door once roughly 63 players are walking.** `welcome`
  plus one replayed path per mid-walk player enqueue as a single atomic step into a fixed
  64-slot send queue, and a full queue closes the connection. So the join burst scales with the
  number of walkers while the buffer does not. `PROTOCOL.md` declares no connection limit in M0,
  which makes this a silent contradiction rather than a stated one. Unreachable at two capsules.
  The first load test that joins a crowded world hits it immediately, and the symptom will look
  like a networking flake rather than a capacity limit. The fix is either a join-sized buffer or
  a chunked join, and it is a decision, not a number.
- **Click-to-first-step latency.** One server round trip by design (see NOTES.md, Movement). If
  it reads as sluggish, the documented escape hatch is cosmetic client-side pathing that
  reconciles when the server path lands. Do not build that until it actually feels bad.
- **Interpolation between ticks.** At a 150ms tick, the client is interpolating most of the
  time. Whether it lerps position or also smooths turning is a feel call.

## Avatar movement feel

Exported on the player avatar, from M0d.

- **`turn_degrees_per_second`, currently `540`.** How fast an avatar swings to face its
  direction of travel. Wrong feels like the body skating sideways through a corner, or like it
  snapping instantly.
- **Whether facing leads or trails the turn.** The body currently turns toward the segment it
  is already on, so it starts turning at the corner rather than before it. RuneScape turns on
  the spot before moving; Marque does not, and nobody has decided whether it should.
- **`face_travel_direction` can be switched off entirely.** Position is unaffected either way,
  and there is a test asserting exactly that.
- **Whether an avatar has any arrival or idle state at all.** It currently just stops. There is
  an `is_idle_at_tick()` hook to hang something off.
- **The facing marker box.** A small box in front of the capsule, because a capsule is radially
  symmetric and its rotation is otherwise invisible in a screenshot. A debug affordance, not
  art. It should go when there is a real model.

## Tick rate

- **150ms is decided and deliberately revisitable exactly once**, when there is enough gameplay
  to feel it. That moment is after M1, when there is an inventory action to time. Not before.
  Revisiting it earlier is re-litigating a settled decision with no new evidence.

## Art direction

- The palette in NOTES.md is diagnostic, not aesthetic. Magenta-for-missing and blue capsules
  exist so an agent can read a screenshot. None of it is a look.
- **When the human wants a look**, that is a separate pass over materials and lighting, and it
  should not touch the semantic colors used by the debug palette.

Shipped values from M0c, all in `client/scenes/main.tscn`:

- Camera `fov` `60.0`.
- `Sun.light_energy` `1.2`, sun angle pitch `-50` yaw `-35`. This sets shadow direction and
  length, which is what makes ground contact readable.
- Ground checker `color_a` `(0.44, 0.44, 0.45)`, `color_b` `(0.33, 0.33, 0.34)`,
  `square_size` `1.0`.
- Player albedo `(0.16, 0.42, 0.88)`.
- `ProceduralSkyMaterial` colors.
- Ground extent `100x100`, and `GroundPicker.ray_length` `4096.0`, which has to stay larger
  than the diagonal from any legal camera position.

**The lit-versus-unlit call.** `NOTES.md` originally prescribed flat unlit materials and now
prescribes lit ones, because unlit ignores the directional light and kills the cast shadow that
makes a capsule look like it is standing on the ground rather than floating. That reasoning is
about legibility, not beauty, so the look pass should revisit it on its own terms.
