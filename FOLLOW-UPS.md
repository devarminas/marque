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

## M1 placeholders

Chosen by the coordinator while scoping M1, all placeholders picked to be decidable rather than
right. None blocks anything.

- **`PickupRange`, proposed `0.5` world units.** How close your feet have to be to an item before
  the server hands it to you. Too small and a walk that lands a hair short leaves you standing
  on the acorn doing nothing; too large and you vacuum up items you walked past. Interacts with
  `MinPathLength`, which is `1e-3`, so there is a lot of room between them.
- **Contested pickup is won by join order.** Deterministic and replayable, which is what a test
  needs, and arbitrary as fairness. It only becomes a real question the first time two humans
  race for something they both want. `PROTOCOL.md`, *Contested pickup*, has the reasoning.
- **Ground items do not despawn and are visible to everyone.** RuneScape hides a drop from
  everyone but the dropper for sixty seconds and then despawns it. Marque does neither, because
  M1 has nothing worth protecting and because a hidden item cannot be contested by two clients,
  which is the entire milestone. Revisit when items have value.
- **Nothing marks a ground item as clickable.** Same gap as "nothing is drawn at the clicked
  point" above, and it will read the same way: the player cannot tell an item apart from scenery
  except by clicking it. RuneScape has hover text and a right-click menu. Marque has a green box.

## The inventory panel, and a compromise forced by the test harness

From M1d. Read the headless-viewport entry in `NOTES.md` first; this is its consequence.

- **A click on the panel's margin, or between two slots, currently walks your character.** The
  panel's chrome is click-transparent and only the slot widgets take input. RuneScape's sidebar
  is opaque and nothing behind it is reachable, which is obviously what a player expects.
  **This is not a design choice, it is a workaround.** The headless viewport is 64x64 whatever
  the project settings say, a 28-slot panel covers all of it, and an opaque panel broke three
  other suites. The fix is a click-blocking background on the panel plus a way for the headless
  suite to test the world without the panel over it, and it cannot be verified headless today.
- **An empty panel hides itself**, for the same reason and with the same smell.
- **Nothing sizes the UI to the window.** The panel is laid out for 1280x720 and there is no
  stretch mode. That is a project-wide decision rather than a number, and it should be made once
  rather than per-element.
- **The click target for a ground item is exactly the drawn 0.5 cube.** RuneScape gives a
  dropped item a generous hitbox precisely because hunting for a pixel is miserable. Feel, so
  parked, but it is the first thing a player will swear at.
- **`apply` frees and rebuilds all 28 slot widgets on every `inventory` message.** Correct, not
  free, and not yet worth measuring at M1's traffic.
- **No hover text, no tooltip, no drag between slots, no right-click menu.** RuneScape has all
  four. None is M1, and all four are what make an inventory feel like an inventory.

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

## Items and pickup

Shipped from M1a. Every number here was chosen to be usable, not good.

| Name | Value | Where | What wrong feels like |
|---|---|---|---|
| `PickupRange` | `0.5` | `server/internal/game/items.go` | Too small and a player who looks like they are standing on an acorn does not take it. Too large and they take it from visibly beside it, then slide the rest of the way. **The only constraint is `PickupRange >= MinPathLength` (`1e-3`)**, a five-hundred-fold margin, because the underfoot case assigns no path and so is never closed by walking. |
| `InventorySize` | `28` | `server/internal/game/store.go` | RuneScape's number. Not really a tuning knob; listed because it is on the wire and a client draws the grid it is told to draw. |

Decisions M1a made that a human may want to overturn:

- **A player's inventory is deleted when they disconnect.** There is no persistence in M1 and no
  drop-on-logout, so whatever they were carrying leaves the world with them rather than falling
  at their feet. It is one line in `World.removePlayer`. RuneScape drops on death, not on
  logout, so this is not obviously wrong; it is just undecided.
- **Join order decides a contested pickup**, which is decidable rather than fair. The first
  player to have connected wins every race they are in. Revisit the first time it feels unfair
  to a human, which needs a human playing.

**This table used to claim `PickupRange` had to stay above `WalkSpeed * TickDuration` = `0.45`,
or a walker could step over an item without entering range.** That was true of the rule M1a was
originally written against, and it died when `PROTOCOL.md` deleted the distance carve-out from
path assignment: a pending pickup's path now terminates at the item and `Advance` lands the
walker exactly on the final waypoint, so resolution happens at latest on the arrival tick for
any range. The old constraint left `0.5` guarded by five hundredths of a unit against a silent
failure. It is corrected here rather than left standing, because this file's whole audience is a
human tuning a number, and a dead constraint is the worst thing to hand them.

## Ground items (M1c)

Shipped values, all in `client/scenes/ground_item.tscn`. Every one was picked to be legible in
a screenshot, not to look like anything.

- **Item box `0.5 x 0.5 x 0.5`, sitting at `y` `0` to `0.5`.** Chosen against the player
  capsule's `1.8` height so the two are not confusable at a glance. Wrong feels like an item you
  have to hunt for on the ground, or one that reads as a crate rather than a thing you pick up.
- **Known-kind albedo `(0.18, 0.72, 0.26)`, unknown-kind albedo `(0.95, 0.08, 0.85)`.** Green is
  Pickup and magenta is missing-asset in `NOTES.md`'s palette, so these are semantics rather
  than art and the look pass should leave the *meaning* alone even if it changes the shade.
- **One mesh for every kind.** M1 ships one kind, so kind currently only picks a colour. The
  moment a second kind ships with its own silhouette, `KNOWN_KINDS` in
  `client/scripts/ground_item.gd` should become a kind-to-appearance table — mesh and material
  per kind, with magenta as the miss — rather than a const array that grows. It is a const array
  today because one entry is not yet a table.

## Ground height, in two places

`ground_y` is now an `@export` on both `player_avatar.tscn` and `ground_item.tscn`, both `0.0`,
because `y` never crosses the wire and the M0 world is a flat plane. They are two copies of one
fact. When terrain lands, both become a query against the same ground service, and they should
move together: an item resting at a different height from the player standing over it is the
failure this note exists to prevent.
