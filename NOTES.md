# Game Notes

Game: RuneScape-like point-and-click farming/crafting, multiplayer, persistent inventory.
Codename: Project Marque.

Client is Godot 4.7, GDScript, **3D with an orbiting camera** above and behind the player.
**Forward+ renderer, desktop only.** Browser export is not a goal, so nothing is constrained
by WebGL limits or by download size.
Server is Go 1.27, single authoritative server. Transport is WebSocket carrying JSON.

Settled decisions that are closed to re-litigation live in
[AGENTS.md](AGENTS.md). This file holds the design detail behind them.

Installed and verified: Godot 4.7.2, Go 1.27.0, git 2.55, gh 2.97.0.

Headless client tests and race recipes live in [AGENTS.md](AGENTS.md).

## Godot authoring traps

Found the hard way while building the M0c scene. Every one is **silent**: no error, no warning,
just a wrong result surfacing far from its cause. Read this before hand-authoring a `.tscn` or
adding a headless test.

- **`Transform3D(...)` in a `.tscn` takes nine basis floats row-major**, not three axis vectors.
  Writing it as `(basis.x, basis.y, basis.z, origin)` gives you the transpose. A sun authored
  that way pointed at the sky, and the scene still looked lit because sky ambient was doing the
  work. Generate the string instead of hand-writing it:
  `print(var_to_str(Transform3D(Basis.from_euler(...), origin)))`.
  ARM-170 walked into this again with this bullet already written, so the guard is now
  mechanical rather than another sentence: `test_grip.gd` asserts each held tool's world AABB
  contains its socket origin, and the transposed grips missed by 0.53 u.
- **`@export var camera: Camera3D` needs `node_paths=PackedStringArray("camera")` on the
  `[node]` header.** Without it the assigned `NodePath` resolves to `null`. Nothing warns.
- **Do not put `uid="uid://..."` on `ext_resource` lines.** Resolving them needs
  `.godot/uid_cache.bin`, which only an editor scan writes, and `.godot/` is gitignored. A fresh
  clone prints `invalid UID` warnings and falls back to the path. Reference by path.
  ARM-181 found `main.tscn` carrying them anyway, so the guard is now mechanical rather than
  another sentence. `test_scene_files.gd` fails on any `ext_resource` line under `res://scenes`
  or `res://tests` that names a uid.
- **Global `class_name` types do not resolve without the editor cache.** On a fresh clone,
  `godot --headless --path client --script ...` fails to *parse* any script that names such a
  type and then cascades into a wall of unrelated inference errors. Use
  `const Foo := preload("res://...")` as the type, or run `godot --headless --path client
  --editor --quit` once first to build the cache.
- **A headless test runner exits 0 when the test script fails to compile.** Zero assertions ran
  and the run looks green. A runner must fail loudly on both "tests did not run" and "tests did
  not finish", or it reports success for a build that never executed.
- **A raycast needs the physics space to have stepped at least once.** Querying
  `direct_space_state` during the first `_ready()` returns nothing useful and looks exactly like
  a broken raycast. Collision layers and masks also default in ways that quietly exclude your
  geometry; set them explicitly.
- **"The screenshot shows lighting" is too weak an assertion.** A build with the sun pointing
  the wrong way passes it, lit by ambient alone. Assert a **cast shadow**.
- **`WebSocketPeer.write_mode` does not exist in Godot 4.7.** The `WriteMode` enum survives,
  which makes stale advice look current. Assigning the property is a **runtime** error, not a
  parse error: the script loads fine and `can_instantiate()` returns true, then the assignment
  aborts the function it sits in. Everything before that line runs, so the process looks alive
  while the socket never opens. Worse, the defaults frame as **binary**: both
  `PacketPeer.put_packet()` and `WebSocketPeer.send()`'s default argument send binary, and this
  server answers a binary frame with an error and a close. The only two safe calls are
  `send_text(s)` and `send(bytes, WebSocketPeer.WRITE_MODE_TEXT)`. Name the mode at the send
  site; do not trust a default.
- **`OS.exit_code` does not exist in Godot 4.7 either.** `SceneTree.quit(code)` is the only way
  to set a process exit code. It does still work from `MainLoop._finalize()`, verified, which
  is how a runner can fail loudly even when `--quit-after` would otherwise exit 0.
- **Headless Godot runs uncapped**, measured at roughly 146 fps on this machine. A frame budget
  is therefore a machine-dependent amount of wall time, and a fast machine can burn a whole
  budget on one network handshake. Pin `Engine.max_fps` for the duration of any time-sensitive
  suite and restore it after.

- **The headless viewport is 64x64, whatever the project says, and it lies to you about it.**
  Measured against 4.7.2, in one run:

  | Probe | Result |
  |---|---|
  | viewport size during `_initialize` | `(100, 100)` |
  | `root.size = Vector2i(1280, 720)`, read back on the next line | `(1280, 720)` |
  | viewport size on the **first frame** | `(64, 64)` |
  | `DisplayServer.window_get_size()` | `(0, 0)` |
  | `window_set_size(1280, 720)` then read back | `(0, 0)` |
  | `display/window/size/viewport_width` in project settings | `1280` |

  **The assignment appears to succeed.** It reads back as the value you set, and reverts by the
  time any frame runs, so a test that sets the size and asserts it immediately passes while the
  suite it protects runs at 64x64. `DisplayServer` is simply absent: it neither sets nor reports.

  This is not a curiosity, it changed the product, and then it changed the tests instead.
  Measured: the panel is 240x432, anchored 16px off the bottom-right corner, so at 64x64 its
  rect is `[P: (-192, -384), S: (240, 432)]` and it covers everything but a 16px strip along
  the right and bottom edges. At the shipped 1280x720 the same panel occupies (1024, 272) to
  (1264, 704).

  **M1d chose the panel and lost.** It shipped the whole chrome as `MOUSE_FILTER_IGNORE`, with
  only the slot widgets taking clicks, so that the suites which need to click the world still
  had a world to click. The cost was a sidebar you could walk through, which RuneScape's never
  is: a click on the drawn panel at (1144, 290) produced `move_to (12.040, -9.565)` and walked
  the player 12.6 units.

  **M1k chose the tests and won.** The panel is `MOUSE_FILTER_STOP` and opaque, and the live
  click aims at the strip it does not cover: `test_wiring.gd`'s `CLICK_AT` is (0.30, 0.88),
  which is (19.2, 56.32) at 64x64 and (384, 633.6) at 1280x720, outside the panel at both
  sizes. `CLICK_AT` exists only in that file, and only that file guards it — it measures the
  rect on a live frame and asserts the constant misses it, so the two cannot drift apart
  silently again. (`test_interaction.gd` measures the same rect for the opposite purpose, to
  find a chrome point it then clicks deliberately.) The lesson is not "avoid opaque UI"; it is
  that a 64x64 viewport makes screen position a scarce resource, and the scarcity is better
  spent on the tests than on the product.

  **Corollary, and it is narrower than this note used to claim.** The sentence here used to
  read "a click outside the 64x64 rect reaches no `Control` at all, so a headless UI test must
  aim inside it". M1k probed that against 4.7.2 with `Viewport.push_input` and found direct
  counterexamples. Each row below is a press and release at one position, with the consumer read
  from `gui_input` on the panel and on every slot rather than inferred from what did not happen:

  | Position | In viewport | Consumed by | Reached `_unhandled_input` |
  |---|---|---|---|
  | (19.2, 56.32) | yes | nobody | yes, picker fired |
  | (19.2, 70), (70, 30), (19.2, 500) | no | nobody | yes, picker fired |
  | (44, 44) | yes | the panel | no |
  | (-50, 40) | **no** | **the panel** | no |
  | (-10, 30) | **no** | **slot 27's widget** | no |

  The rule the data supports is that **`push_input` does not care about the visible rect at
  all**: a `Control` consumes by its own rect wherever that rect lies, and what is left reaches
  `_unhandled_input`. The panel's rect extends 190px past the left viewport edge and its last
  slot's rect extends 14px past, and both consume out there. Whatever experiment produced the
  original sentence was not re-run, so it is narrowed rather than deleted. The practical
  consequence is unchanged and now has a different reason: aim inside the viewport because that
  is where a player's mouse can be, not because a click outside it dies.

  **Consuming and acting are not the same thing, and the gap is silent.** Same probe, two
  occupied slots, both drawn, both inside the panel. Slot 27's rect is (-14, -14)…(38, 38), so
  its centre (12, 12) is inside the viewport; slot 24's rect is (-182, -14)…(-130, 38), wholly
  outside it. A press and release at each:

  | Slot | Centre | `gui_input` | `button_down` | `pressed` | `button_up` | `drop` sent |
  |---|---|---|---|---|---|---|
  | 27 | (12, 12), inside | yes | yes | yes | yes | yes |
  | 24 | (-156, 12), outside | **yes** | no | no | no | no |

  So an off-screen `Button` takes the event away from everything behind it and then does nothing
  with it. **The mechanism is not established and is deliberately not guessed at here**; the
  table is what was observed. The consequence for a test is concrete: a slot that has drifted off
  the viewport edge produces no drop and looks exactly like broken wiring, and no error is
  logged either way, so a headless UI test must assert that the widget it is about to click is
  laid out somewhere visible. `test_interaction.gd`'s `_click_slot` does.

  And `Control.mouse_filter` defaults are not what you would guess. `ColorRect` and `Panel`
  default to `STOP` (`0`); only `Label` defaults to `IGNORE` (`2`). A `ColorRect` background
  swallows its own children's clicks.
- **A `MOUSE_FILTER_IGNORE` panel is a workaround that reads as a design choice, and a test that
  checks `mouse_filter` at one instant does not guard it.** M1d shipped the inventory chrome as
  `IGNORE` so headless suites could still click the world through it at 64x64; a click on the
  drawn panel then walked the player 12.6 units, and a disabled slot `Button` still stopped the
  click while an occupied slot dropped, three behaviours where one was designed. M1k made the
  `PanelContainer` `STOP` and moved `test_wiring.gd`'s `CLICK_AT` to the uncovered strip. The
  suite that guards it asserts the filter a frame or two after an `inventory` feed and never in
  the steady state. A verifier re-armed the filter on every inventory frame and dropped it to
  `IGNORE` seven frames later, and the whole suite stayed green while the panel was click-through
  again. Author `mouse_filter` in the `.tscn`, never at runtime, and if a second panel ever ships,
  add the check that no script assigns it.
- **`%v` in a GDScript format string accepts only vector types, and a `Color` fails it at
  runtime while leaving the assertion green.** Reproduced against 4.7.2, verbatim:

  ```
  ERROR: String formatting error: %v requires a vector type (Vector2/3/4/2i/3i/4i).
  format-with-color returned: [unknown kind draws %v]
  ```

  The script loads, the line runs, the error is logged, and **the expression returns the
  template with `%v` still in it**. So a test whose failure message formats a `Color` degrades
  into an unreadable message while the check itself stays green, and nothing fails. Use `%s`
  for a `Color`.

  Worse, `scripts/interop_test.ps1` cannot save you here: it fails on the *server's* stderr but
  only displays Godot's, and it cannot cheaply be made stricter, because the malformed-frame
  tests deliberately write `push_error` output to that same stream. Writing the trap down is
  the only cheap defence.
- **`godot.exe` output cannot be captured by direct assignment in PowerShell, but pipes fine.**
  Measured on this machine, and the split is exact:

  | Form | Result |
  |---|---|
  | `godot --version \| Out-String` | `4.7.2.stable.official.ed1daf0bf` |
  | `godot --version \| ForEach-Object { $_ }` | captures |
  | `godot --version \| Select-Object -First 1` | captures |
  | `$v = godot --version` | **empty** |
  | `@(godot --version)`, `(godot --version)`, `$(godot --version)` | **empty** |

  So a preflight check written as `if (-not ($v = godot --version)) { fail }` reports Godot
  missing on a machine where it is installed and on `PATH`. **Pipe into a cmdlet, or route
  through `cmd /c`.** The repo's own `scripts/*.ps1` are immune because they hand the process a
  real file handle via `-RedirectStandardOutput` rather than a pipeline.

  **The mechanism is unexplained and is deliberately not guessed at here.** The likely story
  involves `godot.exe` being a GUI-subsystem binary that attaches to the parent console, but
  nobody has established that, and the table above is what was actually observed. It is written
  as behaviour precisely because the last three times somebody here paired a correct behaviour
  with a confident mechanism, the mechanism was wrong.
- **A `static func` cannot take its own script's enum as a parameter type.** Reproduced against
  4.7.2 in `client/tools/build_world_map.gd`: `static func house_spec(door: Side)` called from an
  instance method of the same script fails to parse with `argument 6 should be "Side" but is
  "build_world_map.gd.Side"`. The enum resolves to two different types depending on which side
  of the call it is named from, and nothing warns until the whole script refuses to load. Type
  those parameters as `int` and keep the enum for the call sites and the lookup tables.

**Verify a Godot API exists in 4.7 before writing it into a brief or a gotcha list.** Two
briefs have now named plausible APIs that do not exist in the target version, and both cost a
worker real time. `WebSocketPeer.new().get_property_list()` settles it in one line.

## JSON mode

Autoload singleton, everything emits through it. NDJSON to stdout, one object per line:

```
GAMELOG {"t":142,"ev":"damage","src":"enemy_3","dst":"player","amt":12,"hp_after":68}
```

- Prefix tag so engine warnings can be grepped out.
- `t` = frame number, not wall-clock. Wall-clock makes every run diff differently.
- Gate behind `--json-log` / env var so release builds pay nothing.

### Scripted input (the other half)

Log alone = observe only. Add a JSON input channel to drive the game:

```json
[{"t":0,"action":"move_right"},{"t":30,"action":"jump"}]
```

Run scenario headless → diff event log vs expected. That's a gameplay regression test.

### Determinism — precondition for all of the above

- Seeded `RandomNumberGenerator` per system, no global rand.
- Fixed timestep (`--fixed-fps`).
- No wall-clock reads in game logic.

Without this two identical runs produce different logs and every diff is noise.

## Camera

**3D, orbiting, above and behind the player.** Right-drag or middle-drag orbits the yaw,
the pitch is clamped to a sane arc, and the wheel zooms within a fixed range. The camera
follows the player's position; it never drives it.

- The camera is authored in the scene, never built in `_ready()`. It is static content.
- Camera state is pure client presentation. The server does not know it exists and never
  receives a camera message. Nothing in the protocol references a facing or a view direction.
- Point-and-click needs a ground raycast from the cursor. That raycast is the one place the
  camera touches gameplay input, and it produces an `(x, z)` intent, not a movement.
- Exact orbit speed, zoom limits, pitch clamp, and follow damping are feel, not architecture.
  They are Linear issues labelled `Follow-up` until a human can sit down and tune them.

## Cursor hints

The cursor advertises what a click will do before the player commits to it. One node,
`Main/CursorHint`, owns the shape. Nothing else in the client calls a cursor API, and a suite
proves that by scanning the source of every script under `res://scripts`.

| Under the cursor | Frame |
|---|---|
| Nothing, empty ground, UI chrome, an item, a friendly dummy, your own avatar | `pointer_b.png` |
| A hostile `npc_dummy.gd`, or another player's avatar | `tool_sword_a.png` |
| A `resource_node.gd` | `tool_axe.png` |

A tree gets the tool, not a generic hand, because RuneScape hints a tree with the tool. A
friendly dummy is not a sword: `PROTOCOL.md` has the server refuse an attack on one, so a sword
there would promise what the server denies. Your own avatar is not a sword for the same reason,
and `Session.select_player` already refuses it.

**Hotspots are the first opaque pixel of each glyph in top-down then left-to-right scan order.**
`pointer_b` `(10, 8)`, `tool_sword_a` `(4, 4)`, `tool_axe` `(13, 3)`. The rule is mechanical and
it lands on the drawn tip of all three. It is deliberately not the image centre: a cursor whose
hotspot is the centre picks the wrong thing at the edge of a target and reads as a bug.

**Chrome is a rect walk over the `UI` layer, not `Viewport.gui_get_hovered_control()`.** The
engine's hit test looks like the right answer, because it is the same test that routes the next
click, and two independent design candidates both reached for it. Two things sink it here.

`Hotbar` and `ErrorHud` are `MOUSE_FILTER_IGNORE` at the root, so the engine reports no hovered
control over chrome the player can plainly see, and a sword would be drawn over the interface.
And `hotbar.gd::_input` rect-tests its own slots and calls `set_input_as_handled()` while those
slots are `IGNORE`, so the engine also reports no hovered control over a widget that does eat the
click. That second one only bites in the shipped client: `hotbar.gd` returns early when
`get_visible_rect().size.x < 200.0`, so at the headless 64x64 viewport the hotbar consumes
nothing and no suite can reproduce it.

So the rule is any `Control` descendant of the `UI` `CanvasLayer` that `is_visible_in_tree()` and
whose `get_global_rect()` contains the pointer. It derives from the scene, so a new HUD needs no
registration, and it needs no answer to whether Godot refreshes hover for a pointer that has not
moved.

The cost is ARM-158: a click on the `Hotbar` or `ErrorHud` background, and on the always-visible
`ClassDebug` strip, still reaches the world while the cursor shows the pointer. The fix is
`mouse_filter` in the scene, which is a click-behaviour change, not a cursor change.

**The cursor re-derives on mouse motion, and otherwise only when a cheap check says the last
answer expired.** A ray every frame under a motionless mouse is waste; never re-deriving leaves a
sword on a hostile that died. The invalidation set is the chrome verdict, the watched body's
`is_instance_valid` and `is_inside_tree`, the watched body's `global_transform`, and the camera's
`global_transform`, all compared exactly rather than approximately. `Session._forget_npc` does
`remove_child` then `queue_free`, so a despawn trips the liveness check on the next frame.

That set still cannot see a body arriving under a motionless cursor, or a `faction` flipping
without movement. A scene-authored `CursorHint/Recheck` `Timer` bounds those to its `wait_time`
instead of leaving them stuck, the way `ErrorHud/Linger` bounds the error toast.

**At the headless 64x64 viewport the visible `Hotbar` covers the viewport centre** (its rect is
`(-32, -8) 128x60`) and `InventoryToggle` covers centre plus `(16, 0)`. A suite that hovers the
centre expecting bare world gets the chrome answer until it hides the hotbar, and one looking for
empty ground beside a body must offset left, not right. Same scarcity that moved
`test_wiring.gd`'s `CLICK_AT`.

## Color as semantics, not decoration

**Lit materials, fixed palette.** This said "flat unlit" and that was wrong for a 3D orbiting
camera. Unlit geometry ignores the `DirectionalLight3D` entirely, so there is no cast shadow,
and without a shadow a capsule standing on a plane has no readable contact point or depth.
The palette's job is that a screenshot is legible at a glance, by a human and by an agent
reading a captured PNG, and lighting serves that job rather than fighting it. The colors below
are unchanged and remain semantic, not decorative.

Fixed palette:

| Color | Meaning |
|---|---|
| Magenta | Missing asset — loud failure |
| Red | Hostile |
| Blue | Player / friendly |
| Yellow | Interactable |
| Green | Pickup |
| Orange | Hazard / trigger volume |
| Gray | Static world geometry |

- Magenta-for-missing is the important one. Missing model should scream, not render nothing.
- Readable from a screenshot at a glance — by me and by an agent reading a captured PNG.
- Pair with a world-space checker material (1m squares, driven by world pos, no UVs) so scale is readable on untextured primitives.

## World scale

**One Godot unit is one metre, and the player stands about 1.7 units tall.** The acceptable
band is 1.6 to 1.8. Environment, enemies, and tools are sized against that player, never per
mesh. The orbiting camera reads scale off the player, so a 2.5 m player makes a correctly sized
tree look like a shrub.

Normalise at import, not per scene. For a scene-imported format the knob is the `.import`
sidecar's `nodes/apply_root_scale=true` plus `nodes/root_scale=<factor>`, which every scene
importer in this repo already writes. An instance node that needs its own scale to be on
contract is a sign the import is wrong.

Per-asset authored heights, the sources that are off contract today, the root-scale
arithmetic, and the import settings per format live in `client/assets/README.md`.

**Hand tools are no longer an exception.** Godot imports `.obj` natively as a bare `Mesh`, so
there is no scene importer and no `nodes/root_scale`, but the sidecar's `scale_mesh` reaches the
vertices and is that knob under another name. `axe.obj.import` carries
`scale_mesh=Vector3(0.1357, 0.1357, 0.1357)` for a 0.90 m axe from 6.631 u and
`pickaxe.obj.import` carries 0.0588 for a 0.85 m pickaxe from 14.466 u. Each factor is stated
once, on the mesh, and the five nodes that used to restate it keep only rotation and offset:
four under `Grip` in `client/scenes/player_avatar.tscn`, and `Model` in
`client/scenes/ground_item_lumberjack_axe.tscn`. The four Weapons pack `.glb` files are on
contract and take scale 1. Converting the tool pack to glTF is now a materials question alone.

Every offset on those five nodes kept its old number, and that is not an oversight. A
`Transform3D`'s origin lives in its parent's space and is never multiplied by that node's own
basis, so the sockets' 0.4071 and 0.5586 and the dropped axe's `(0.067839, 0.052991, 0.569979)`
were metres already. They were each derived as mesh units times the factor, which is the only
reason they look like they should scale with it.

## Hand sockets. Tools follow the rig from outside the girth scale

**`Grip/left hand` and `Grip/right hand` are unscaled siblings of `Body`, not `BoneAttachment3D`
children of the skeleton.** They follow their bone by setting their own local transform on
`Skeleton3D.skeleton_updated`:

    transform = body.global_transform.affine_inverse() * skeleton.global_transform
        * skeleton.get_bone_global_pose(bone)

The reason is ARM-169. `apply_class` sets `Body.scale` to `(0.78, 1.0, 0.78)` so the bare skin
shrinks inside the outfit, and `Body` is the skeleton's ancestor, so anything parented under the
skeleton inherits that squash. The outfit sleeves do not: they are unscaled siblings rebound to
the same rig, so they render at full girth. A tool on a plain `BoneAttachment3D` therefore lands
**5.8 cm inside the sleeve it is supposed to be held by**, measured on `hand_r` in
`ual2/Walk_Carry`, and the offset breathes with the animation. `use_external_skeleton` is not a
way out; it multiplies by the skeleton's full global transform, girth included.

The expression above cancels the girth algebraically rather than approximately, because
`body.global` is `W·R·Sg` and `skeleton.global` is `W·R·Sg·A·K`, so the product is exactly `A·K`.
It also survives girth moving somewhere else later, which is why it is written as an inverse
times a global instead of dividing by `DRESSED_GIRTH`. Setting the **local** transform, not the
global one, is what keeps the socket inheriting the avatar's own position and yaw for free.

`Grip` carries the same 180 degree yaw `Body` and every `Outfit/*` part carry, and it has to:
the expression cancels `Body`'s transform down to `A·K`, so the socket's parent must supply the
yaw that `Body` was supplying. `test_grip.gd` pins that against the sleeve rather than against
the number, so a `Grip` authored at identity fails the suite instead of drawing tools behind the
player.

**Which mesh is shown is the only runtime part.** All six kinds are authored hidden under each
socket and toggled by name, exactly as `Outfit/*` parts are, so there is no instantiate path and
no way to end up holding two of anything.

**Handedness is never copied to the client.** A two-handed kind arrives occupying both hands
(`PROTOCOL.md`, *Handedness*), so `grip_defs.gd` infers it from the restatement with one string
comparison and collapses the pair onto the right hand. `equipment` is sent to one player and
never broadcast, so only the local avatar can hold anything; remote avatars are empty-handed by
protocol, not by bug.

## Backend — Go

No physics to share with the client, so no reason to run Godot on the server.
The game is a database with a game attached; Go has the ecosystem for that (pgx).

| Piece | What | Owns |
|---|---|---|
| Client | Godot / GDScript | Render, input, interpolation. Zero authority. |
| Server | Go | Tick loop, all state in memory, all validation |
| DB | Postgres | Durable state, written transactionally |
| Transport | WebSocket | Godot `WebSocketPeer` ↔ Go |

- `AGENTS.md` owns the invariants (intents not facts, client state is a cache, one goroutine
  owns the state). The reason is the dupe section below. Every rule there assumes the server is
  the only writer.
- Shared data (items, recipes, XP tables, map) = JSON in one folder, read by both. One source of truth, two languages.

## Movement. The client sends an intent, the server returns a polyline

```
→ {"move_to":{"x":42.3,"z":17.8}}
← {"path":[[10.0,4.0],[14.2,6.1],[42.3,17.8]],"speed":3.0}
```

**Coordinates are ground-plane `(x, z)`, floats, in Godot's world units with `y` up.** The world
is 3D but movement is not: the server stores and paths over two axes, and `y` is whatever the
ground is at that point. The server never sends `y`. This keeps the navmesh, the polyline, and
every future position broadcast two-dimensional, which is both smaller on the wire and the
reason a 2D A* is sufficient. RuneScape does the same thing, a plane with per-tile height.
Revisitable if verticality ever becomes a game rule rather than scenery, which would mean
bridges you can walk under. It does not today.

- Pathfinding lives only on the server (`AGENTS.md`), because a client pathfinder is a second
  copy that diverges.
- Client walks the polyline and interpolates → smooth movement regardless of tick rate.
- Cost is one round trip before the character moves. That was written for click-to-move, which
  the client no longer has (ARM-145); WASD pays the same round trip.
- Send waypoints, not per-tick positions.
- Server validates the destination is reachable. Reject unreachable destinations, don't silently snap to nearest.
- Optional later: client paths cosmetically with Godot's `NavigationServer` for instant response, reconciles when server path lands. Only if the round trip feels bad.

### Navmesh pipeline

Bake in the Godot editor → export vertices/polygons as JSON → Go loads at boot.

```json
{"vertices":[[0,0],[4,0],[4,4]], "polygons":[[0,1,2]], "hash":"a3f9..."}
```

- A* over polygon adjacency + funnel string-pulling. A few hundred lines of Go.
- Don't need Detour's full feature set (tile streaming, off-mesh links, crowd avoidance) — mostly-flat ground with static obstacles.
- **Hash the mesh, ship it in both builds, server refuses to boot on mismatch.** Stale mesh = players walk through walls and it looks like a gameplay bug, not a build bug.
- Make the export a build step. Anything manual gets skipped.
- Unverified: that `NavigationMesh` vertex/polygon export round-trips cleanly. Check before designing the map format around it.

## Tick rate

The rule is settled in `AGENTS.md` (and historically as standing order item 4): 150 ms, one named constant on the server,
nothing else hardcodes a tick duration, revisitable once when there is gameplay to feel. The
reasoning:

- Tick rate and movement smoothness are independent. Client interpolation handles smoothness.
- Fast ticks are only needed when sub-tick position changes a game rule (PvP collision, hitboxes). Not this game.
- 600ms is RuneScape's deliberate mechanical feel and 150ms reads as modern and responsive.
  We took responsive. The farming and crafting loop is the draw here, not combat timing, so the
  tick is a scheduling grain rather than a skill expression. The cost is 4x the broadcast volume
  of a 600ms tick, which is irrelevant at this player count.
- Discrete ticks make the server replayable: record inputs → feed a fresh server → diff state. Build the tick loop with replay in mind from tick zero.
- Positions are floats now, so replay diffs need epsilon compare, not equality.

## Persistence — dupe bugs are the thing that will hurt

Item duplication is the defining failure of this genre. A dupe found in production is unfixable after
the fact — you can patch the hole but not un-print the items.

- Every inventory change is one transaction. Trades/bank touch two inventories — same transaction or neither.
- Requests idempotent. Sequence-number every request, dedupe server-side. Reconnect must not double-apply.
- Validate against server state only. Client sends slot indices; server looks up what's actually there.
- Never delete-then-insert. Move within a transaction.
- Postgres over SQLite even for one server.

## Milestones

The program is tracked in Linear, project *Project Marque*
(`https://linear.app/arminas/project/project-marque-525be456de70`). The ordering principle is
to retire the riskiest assumption first. The risk is multiplayer and persistence colliding, not
gameplay content.

- **M0, complete.** Two clients connect, click to move, and each sees the other walk. Proved the
  transport, the tick loop, the polyline protocol, and the event log, with pathfinding stubbed to
  a straight line.
- **M1, complete.** Two clients click one item on the ground and exactly one gets it. Proved
  server authority, contested resolution, and a transactional inventory write in both directions
  (pickup and drop), behind an in-memory `Store`.
- **M2, in progress.** A client whose socket dies mid-action comes back as the same player with
  the same inventory, and an intent it sends twice is applied once.

Later: real navmesh, auth and accounts, skills and XP, multiple recipes, map content, interest
management, Postgres behind `Store`.

### Decisions the early cuts fixed

- Auth is hardcoded player ids. Known work, zero risk, pure time.
- Art is magenta and blue capsules and one green box for the ground item. A ground item in M1
  is a pickup and nothing else, so it is green per the palette above. An item kind the client
  does not recognise is magenta.
- Drop before crafting. Drop is pickup's reverse transaction, so it tests atomicity in both
  directions with zero content work. Crafting is CRUD and not where the risk lives.
- The contested-pickup test is automated, two scripted clients on the same tick. It is not a
  thing to check by hand with two windows.
- The JSON event log was built into the Go server from tick zero. Retrofitting after inventory
  exists would mean touching every mutation twice.
- Navmesh, A*, and funnel are one to two weeks that produce nothing playable, so a straight-line
  stub shipped first. The polyline protocol does not care where the points came from.

### Tab targeting (M6c)

Left-click on another living player selects them (yellow ring under the feet). Selection does
not send `attack`. Escape clears the selection (after any pending inventory use-on). A ground
click does nothing at all and leaves the selection alone (ARM-145). Self and corpses are not
selectable as hostile targets.

### Right-click basic attack (M6f)

Right-click on a hostile (remote player or enemy practice dummy) sets selection to the clicked
actor and sends `attack`. Friendly dummies are selected but refused (no pending attack).
Left-click stays select-only.

### Bag slot gestures (ARM-151)

A bag slot carries three gestures, and every one of them needs the bag open. Left-click is the
two-click use-on chain: the first names the source slot, the second sends `use`. Right-click
sends `equip`. **Shift + left-click sends `drop`**, which is RuneScape's own shortcut and the
tiebreaker for a client with no right-click menu to hang a Drop entry off.

Drop had no gesture at all between the two-click use-on landing and ARM-151. Use-on took the
plain left-click that used to drop, nothing replaced it, and `Session.request_drop` sat with
zero production callers for four milestones. Nothing caught it because the only proof that
drop works end to end is `contested_pickup_demo.ps1`, which was red for an unrelated-looking
reason and waived.

The bag starts closed and `toggle_inventory` (`I`) opens it. A slot widget under a closed dock
is still laid out at a plausible on-screen rect, so `get_global_rect()` reads healthy while
`push_input` at its centre reaches nothing: the viewport skips controls that are not visible in
the tree, and the click falls through to the ground picker, which since ARM-145 does nothing at
all.

**Showing a `Control` does not lay it out, and the stale rect it leaves behind is on screen.**
`_dock.visible = true` (or the toggle key) flips visibility synchronously, but the container
re-sorts on the next layout pass, so a `get_global_rect()` read on the same frame returns where
the widget sat while hidden. Measured at 1280x720: bag slot 0 read `(1050, 126)` on the frame
the bag opened and `(1050, 332)` once it settled. **Both are inside the viewport**, so a bounds
check passes on the stale one and the click lands on empty chrome, silently. Wait for the rect
to stop changing between frames before reading a centre to click.

### Player body and UAL2 locomotion (ARM-168)

The player avatar is the Quaternius Universal Base, `Superhero_Male_FullBody.gltf`, driven by
two UAL2 clips out of `client/assets/quaternius/animations/locomotion_library.tres`. Standing
height in idle, measured by `client/tests/avatar_height_probe.tscn`, is **1.733 u** at
`root_scale` 1.0, inside the 1.6 to 1.8 band. The probe reads that off the rendered silhouette,
so it also measures a 1.7 u box standing in the same frame as its own control; that box read
1.702 u, which bounds the method's error at a few millimetres. The bind pose is 1.820 u, the
figure `test_avatar.gd` asserts to catch a stray `root_scale`, and the idle pose stands 8.7 cm
shorter than it. The animated body therefore lands on contract with no sidecar correction, and
the outfit parts ARM-169 layers on the same skeleton need none either.

**The two clips are substitutes, chosen knowingly.** UAL2 Standard ships no neutral idle, no
neutral walk, and no run. Every idle is situational and the only walks are `Walk_Carry_Loop`
and `Zombie_Walk_Fwd_Loop` (`client/assets/README.md`, finding 7). Keeping the KayKit clips was
not available, because the Knight and the Universal Base are different skeletons. So idle is
`Idle_FoldArms_Loop` and locomotion is `Walk_Carry_Loop` at every speed. The player stands with
folded arms and walks as though carrying something. That is accepted and reversible, and the
decision is recorded on ARM-168 in the owner's comment of 2026-09-08. A purchased neutral set,
or the fuller paid Universal Animation Library, retires it by changing two constants in
`player_avatar.gd` and rerunning the bake.

`Walk_Carry` covers 0.6527 u/s of ground at `speed_scale` 1.0, measured by
`client/tests/bake_ual2_library.gd` from the planted toe and carried in `player_avatar.gd` as
0.65. The avatar plays it at path speed
divided by that, 4.62x for the server's 3.0 u/s, so the feet match the stride instead of
sliding. It reads hurried. A real walk or run clip fixes that through the same constant.

Godot's scene importer strips the vendor `_Loop` suffix into `loop_mode`, so the library keys
and the script constants are `ual2/Idle_FoldArms` and `ual2/Walk_Carry` while the GLB and the
Linear thread say `Idle_FoldArms_Loop` and `Walk_Carry_Loop`. Same clips.

A broken body path does not fail the scene load. Godot logs a parse error, drops the node, and
instantiates an avatar with no `Body`. `player_avatar.gd` catches that in `_ready` and shows the
authored `MissingBody` magenta capsule, per the palette above.

### Class outfits and recolors (ARM-169)

The worn set implies a class, the client dresses the avatar. Five classes, two Quaternius
Modular Fantasy outfits, one tint each. `client/scripts/outfit_defs.gd` is the whole mapping:
a table keyed by class id, no branching, and the only file to touch when a class is added.

| Class | Outfit | Tint |
| -- | -- | -- |
| Archer | Ranger | leaf green |
| Knight | Ranger | cool steel blue |
| Mage | Peasant | violet cloth |
| Miner | Peasant | dusty ochre |
| Lumberjack | Peasant | deep work green |

No class, or an incomplete set, wears nothing: the bare Universal Base at full girth. That is a
different silhouette from all five kits, not a muted version of one.

**The parts are authored in `player_avatar.tscn`, all ten of them, all hidden.** Which parts are
*shown* is runtime behaviour and lives in `apply_class`; which parts *exist* is fixed, so they
are scene content. The parts sit under an `Outfit` node beside `Body`, never under the base
`Skeleton3D` — `test_avatar.gd` iterates that skeleton's mesh children and asserts things about
each one, and parking clothes there would silently change what that loop covers.

**A part follows the animation because its `skeleton` NodePath points at the base rig,** not
because anything reparents it. Every Quaternius part ships the same 65-bone armature with the
same rest pose, so pointing the part's `MeshInstance3D.skeleton` at `Body/Armature/Skeleton3D`
binds it to the pose the `AnimationPlayer` is already driving. The part instance carries the
same 180-degree transform as `Body` so its global transform matches the skeleton's; without
that the skinning is computed in the wrong space. A part that rides the root transform without
deforming is the failure this arrangement avoids, and `test_outfit.gd` asserts the shared
`Skeleton3D` object identity rather than the mere presence of a path.

#### The pack's head-only rule, and why the obvious reading of it is unbuildable

`client/assets/quaternius/outfits_fantasy/Readme.txt` says only the head of the base model is
required and that using the full body will clip. **The pack ships no head-only mesh.** The base
glTF has three mesh nodes — `Eyebrows`, `Eyes` and `SuperHero_Male` — and `SuperHero_Male` is a
single primitive on a single material covering the body and the head together. There is no
surface to keep and no surface to drop. `Head` in that file is a bone. Splitting it needs a DCC
tool, and none is installed here.

So the rule was satisfied by measurement instead. The clipping is real and visible at this
game's camera distance (14 u, -35 degrees, roughly a hundred pixels of character): the bare
back, shoulders and shins punch through the tunic and trousers on both outfits, in idle and
mid-stride, from in front and behind.

Two obvious fixes were tried and rejected on the evidence:

- **Uniform shrink of `Body`.** Scaling to 0.86 does clear the cloth, because the whole figure
  sinks. That sinking is also what kills it: the head drops into the collar and, from the front,
  disappears entirely. Pivoting the scale at the neck keeps the head but leaves the shoulders
  exactly where they were, so the clipping comes straight back. Uniform scale cannot shrink the
  torso and hold the head, because the drop is the mechanism.
- **Hiding `SuperHero_Male`.** Zero clipping, and the silhouette is clean. It also leaves the
  Peasant with no head at all and the Ranger with a hollow inside the hood, because the hood has
  a face opening and nothing behind it.

**What works is shrinking girth alone: `Body.scale = Vector3(0.78, 1.0, 0.78)` whenever an
outfit is worn.** The torso, hips and legs pull inside the cloth; the head keeps its exact
height, position and vertical size. It is one number and it is reversible. The bare avatar stays
at `Vector3.ONE`, so nothing changes for a player with no class.

The visible skin that remains is the arms and hands, and that is the outfits' own geometry, not
a leak: `Male_Peasant_Arms` and `Male_Ranger_Arms` each carry an `MI_Regular_Male` surface for
the bare forearms and hands. Hiding the base body entirely still leaves a full bare arm, which
is how that was established.

#### Tinting

A tint is `albedo_color` on a duplicate of the part's own material, which multiplies the vendor
albedo texture, so the fabric detail survives the recolor. Only surfaces whose material name
starts with `MI_Peasant` or `MI_Ranger` are tinted. `MI_Regular_Male` is left alone, so the
hands never take the class colour. The check is written to fail closed: an unnamed material is
not tinted rather than tinted by accident.

#### Remote players stay bare, and that is the protocol

`PROTOCOL.md` sends `class` to one player only and never broadcasts it. The client therefore
knows its own class and nobody else's, so remote avatars wear the bare base body. Dressing them
needs a server-side broadcast, which is out of scope for an art-only remap; ARM-169 explicitly
required no new `shared/` rows and no server change.

#### A multiply tint cannot add a colour the texture does not have

The Knight was specified as "Ranger, cooler/metal-leaning tint". A blue `albedo_color` over
`T_Ranger_BaseColor` does not produce a blue Ranger, because `albedo_color` multiplies: the
texture's blue channel is near zero on the green cloth, so the blue tint has nothing to scale up.
The first palette put Archer and Knight 0.034 apart on a 0.10 floor, two dark green hooded figures
that a player could not tell apart.

**They separate on value, not hue.** Archer is brightened (`albedo_color` above 1.0 is legal and
does scale up, which is the only way to make the vendor green read bright) and Knight is pushed
dark and cool until it reads as near-black steel. The five tints are the ones the probe passes
with margin, not the ones that looked reasonable in a table.

#### The probe measures the whole avatar, not one patch

`client/tests/class_outfit_probe.tscn` stands all five classes plus a bare avatar in one frame at
the real game camera, then compares each pair.

The first version averaged a torso patch per avatar and compared mean colours. That metric is
wrong twice over: on the Ranger it sampled the brown belt rather than the tunic, and mean colour
throws away silhouette, which is half of what separates a hooded Ranger from a bare-headed
Peasant. Tuning the palette to satisfy it made the palette worse, not better, and drove Archer
into Lumberjack's green.

The probe now crops each avatar and compares the crops **pixel for pixel**, so a tint difference
and a silhouette difference both register. Every pair lands between 0.203 and 0.281 against a
0.12 floor. It prints the crop size and refuses a zero-pixel crop, because a comparison over no
input passes vacuously.

### Gather node trees (ARM-171)

A woodcutting node is `client/scenes/resource_node.tscn`, and it draws the Quaternius Stylized
Nature MegaKit `CommonTree_1.gltf` instead of a cylinder and a sphere. The tree is instanced at
`root_scale` 1.0 and carries no instance scale. It measures **6.819 u** of drawn silhouette in
`client/tests/gather_tree_probe.tscn`, beside a 1.736 u player and a 1.7 u control box that the
same frame reads as 1.694 u. Nearly four times the player is the right size for a tree.

Read the mesh bound carefully, because two different numbers both describe this tree. The AABB
spans **7.265 u**, and `client/assets/README.md` lists it under that figure, but it runs from
y −0.243 to y **7.022**: a quarter metre of root sits under the ground plane the node stands on.
So 7.022 u is what a player sees, and the silhouette falls 0.203 u short of that because the
topmost leaf cards are edge-on and cover no pixels. Against 7.265 the same gap looks like half a
metre of missing tree. `test_nodes.gd` asserts the 7.265 u extent, since that is what
`get_aabb()` returns.

The probe refuses a measurement over nothing. `_silhouette_height` returns 0.0 when every pixel
in its band is background, which would have printed `TREE PROBE full 0.000 u` and exited 0, so
each height must clear a floor, the 1.7 u control must read back within 5 cm before any other
number is believed, and the tree must stand over both the player and its own stump.

**The node shows exactly one of three authored visuals, chosen by an enum.**

| `Look` | When | What is authored |
| -- | -- | -- |
| `TREE` | known kind, `full` | the `CommonTree_1.gltf` instance |
| `STUMP` | known kind, `depleted` | a 2.0 u tapered cylinder in the weathered depleted brown |
| `MISSING` | unknown kind, either state | a 2.2 u magenta capsule, the palette's loud failure |

`look_for(kind_known, state)` is pure and total, and `_show` is the only thing that writes
visibility. The old code spread depletion across three channels at once. It hid `Foliage`,
swapped `Trunk.material_override`, and squashed the whole body's `scale` to `(0.7, 0.55, 0.7)`.
That is eight reachable combinations of which three were legal, and no variable answered "what is
this node showing". The proof is that the old test could only assert a disjunction, "depleted
changes scale, color, or foliage visibility". The enum gives that question one answer and makes
the illegal combinations unreachable. `resource_node.gd` never writes `scale` now, and
`test_nodes.gd` asserts it stays `Vector3.ONE` through a depletion.

**Foliage cannot be hidden by hiding a node.** Every `CommonTree_*.gltf` is one glTF node holding
one mesh with two primitives, bark and leaves, so there is no canopy child to toggle, and
`material_override` would recolour both surfaces together. That is why depletion swaps whole
visuals instead of editing the tree.

**The stump is a scene primitive because no stump asset is staged.** `DeadTree_*` and
`TwistedTree_*` were deliberately left out of the tree; `client/assets/README.md` records why.
When one is staged, `StumpVisual` becomes an instance and no script changes.

**Two colliders, because the canopy is most of what a player aims at.** `TrunkShape` is a
cylinder of radius 0.6 spanning y 0 to 2.6 and is never disabled, so it always contains the
y = 1.8 point the gather demos click and always catches a ray dropped from straight above.
`CanopyShape` is a sphere of radius 2.2 spanning y 2.48 to 6.88 and is disabled outside `TREE`,
so a stump carries no invisible hitbox where its canopy used to be.

Neither of the first two rays ever touched the canopy. A ray dropped from y 6.0 starts inside the
sphere, and `intersect_ray` skips a shape containing its origin unless asked otherwise, so it fell
through to the trunk; the y = 1.8 ray sits below the sphere's 2.48 floor. `canopy_shape.disabled`
was therefore asserted only as a boolean. `test_nodes.gd` now casts a third ray at canopy height,
1.5 u off the trunk axis where nothing but `CanopyShape` sits, and requires it to find the tree
while full and to find nothing once depleted. It also reads the mesh AABB and asserts the trunk
reaches the ground, the two hitboxes overlap rather than leaving an unclickable band between
2.48 and 2.6, and the canopy sphere covers the drawn crown's 7.022 u height and 2.29 u
half-width to within 0.3 u. Swapping in `CommonTree_3` at 9.425 u without moving the collider
fails those.

#### The two-client demo's sky band, broken by ARM-171 and repaired by ARM-183

`scripts/two_client_demo.ps1` asserts that the top quarter of a still client's two frames is
byte-identical, on the premise that the top quarter is sky. A 7 m tree draws there, so
**`two_client_demo.ps1` exits 1 on this branch**. It is red, not merely noisy, and ARM-183 has to
land before anything depends on that harness being green.

Measured on client a's still pair, **13 pixels out of 230,400 differ: 12 by one step in one
channel and one by 46**. All are canopy green, inside x 1006..1161, y 26..176. Client b's still
pair differs by **0 of 230,400** in the same band, because its camera does not frame the tree up
there, which is why only one of the two clients fails.

Two details matter for whoever writes the fix. The count is not stable: an earlier run of the
same build read 8 differing pixels over a smaller box, so a tolerance needs headroom rather than
a threshold fitted to one run. And the 46-step pixel is not rounding noise, it is a leaf edge
crossing the material's 0.2 alpha-scissor threshold, so a per-pixel tolerance small enough to
stay meaningful will not cover it. A band chosen to exclude world geometry is the better fix
than a tolerance.

None of this is the intermittent sky-band flake, and none of it is a walk regression. The flake
clusters under GPU load; this reproduces on an idle machine and only with the tree. Geometry is
identical to the merge base to the digit: both walks 6.204 u, destinations 8.435 u apart, both
arrivals at (-1.378, 6.049) and (5.928, 1.831) 14 ticks after their paths. Every behavioural
assertion in the demo still passes; only the control fails.

The cause is not the leaf material, which already imports as alpha-scissor with alpha
antialiasing off, so its coverage is deterministic. The project sets no MSAA, TAA or
screen-space AA either. What remains is the shadow pass: the tree is a double-sided
shadow-casting receiver, and the other client's avatar walks through that pass between the two
frames. Turning the tree's shadow off would settle the band and is exactly the wrong trade,
since a cast shadow is this repo's standard anti-false-pass assertion.

**ARM-183 took the tolerance route anyway, and it works.** Everything above is ARM-171's branch,
kept because its measurements are what the fix was sized against. At most 0.5% of the band's
pixels may differ and no channel of any pixel by more than 2 of 255. The walking pair goes
through the same test and must fail it, so a green run prints both sides of the boundary. The
intermittent flake this section contrasts itself against is no longer a category, because the
noise it named sits inside the tolerance. **A sky-band failure is a finding.**
`.claude/skills/verify-marque/SKILL.md`, *The still-camera control*, carries the measurements.

### Retiring the KayKit tree (ARM-173)

`client/assets/kaykit/` is deleted, not tombstoned. ARM-168, ARM-169 and ARM-170 had already
moved the player body, the outfits and the hand tools onto Quaternius and the tool pack, so
nothing loaded the directory except one prop scene.

The deciding fact is licensing, not tidiness. A tombstone leaves unlicensed binaries in a public
tree; the whole argument is `client/assets/README.md`, finding 5.

`client/scenes/ground_item_lumberjack_axe.tscn` was the last consumer. It now draws
`tools/axe.obj` at 0.1357, the same correction the hand socket applies, laid flat along Z and
centred on the body origin. Measured through `GroundItem.local_bounds()`: 0.900 u long, 0.106 u
tall, resting on y 0.00007. The KayKit prop stood upright and read 1.244 u.

**The drawn axe is longer than the body that catches the click, and always was.**
`ground_item.tscn`'s `BoxShape3D` is 0.5 u on a side at y 0.25, and ARM-173 did not touch it, so
the click target is exactly what it was before. But 0.900 u of axe in a 0.5 u box leaves the
head and the butt of the handle unclickable, and the KayKit prop overhung the same box in Y
instead. Nothing observed has broken on it: `gather_error_demo.ps1` clicks a seeded
`lumberjack_axe` at the body origin and the server resolves the pickup. Sizing the collider to
the drawn model belongs to whoever gives ground items their own per-kind shape, which no unit
owns yet.

### Open-world map with three towns

`client/scenes/world_map.tscn` is a 256 x 256 u world, the same square the server already
clamps movement to (`WorldHalfExtent` 128), with three towns on a triangle and a Y of dirt roads
meeting at a hub. ARM-199 instances it from `main.tscn` as `WorldMap` and drops the old 100 x 100
checker, sun, and environment so the map owns lighting and the walkable ground.

**The scene is generated, then committed, and the generator is the thing to edit.**
`client/tools/build_world_map.gd` writes the `.tscn` text from a fixed seed:

```powershell
godot --headless --path client --script res://tools/build_world_map.gd
```

Two runs produce a byte-identical file, so a regenerated scene with no diff is proof that the
generator did not change. The scene-authoring rule in `AGENTS.md` still holds: the committed
`.tscn` is what the editor opens, what diffs, and what the game loads, and nothing at runtime
builds it. The generator exists because 3,011 instanced nodes are not hand-placeable, and it
stays because a hand edit to the scene is lost on the next run. Move a house by moving its lot
in `town_table()`, not by dragging it in the editor.

**The world is a set of tables, and one placer reads them.** `town_table()` holds three towns
and 22 hand-designed lots, each a `house_spec` at an offset and yaw in town-local space, where
local +z is the side that faces the hub; the whole town is then yawed to face the hub, so a lot
table is designed once with the road entering from the south. `region_table()` holds the nine
forest regions (a rim band past |x| or |z| > 100, three elliptical woods, five copses) with their
keep chance. `scatter_table()` holds four rules keyed by an `Allow` enum. Forests and scatter
both come from a jittered grid filtered by pure predicates over `Vector2`: `inside_world`,
`outside_towns`, `road_clearance`, `inside_region`, `scatter_allows`. The alternative, a loop
per category with its own exclusion arithmetic, was rejected in the brief before any code was
written, and the generator was table-driven from its first draft.

**Houses are assembled from the Medieval Village MegaKit's 2 u modules.** `add_house` takes a
footprint in modules, a storey count, a ground and an upper `Style` (plaster or brick), and a
door side, and emits floor tiles, one wall module per 2 u of perimeter per storey, corner
posts, a `Roof_RoundTiles_WxL` matched to the footprint, `Roof_Front_Brick{W}` gables at both
ends, and a chimney on the slope. The kit's wall module is 2 u wide by 3 u tall with its wood
trim on the -z face, so a wall's yaw is a function of which side of the house it closes and
nothing else (`SIDE_YAW`). Windows are drawn by the seeded RNG at `WINDOW_CHANCE`, and a door
is one module on the door side with the frame and a `Door_1_Flat` hinged at the wall's local
x -0.51, ajar by up to 0.35 rad on three houses in ten. The probe render that settled the
recipe (trim outward, roof seated on the wall top, gable under the ridge) is in the PR.

Paving sits at y 0.05 and roads at y 0.03. Each road segment is a unit `PlaneMesh` scaled to
(width, 1, length + width) so consecutive segments overlap at the bends instead of leaving a
wedge of grass; the price is that the last segment overruns its end by half a road width, which
is why the plaza and hub bricks are raised over the road rather than the road shortened.

**Measured on this machine**, RTX 2070 SUPER, 1280 x 720, Forward+:

| What | Value |
|---|---|
| instanced nodes (roads, towns, forests, scatter) | 280, 1293, 974, 464; 3,011 of a 4,500 budget |
| scene tree after load | 6,094 nodes |
| `world_map.tscn` | 593,577 bytes |
| probe fps after a 40-frame settle | 56 to 64 across three runs |
| headless suite | `PASS: 1777 assertion(s) held across 34 suite(s)` |

Every forest tree is its own instanced scene rather than a `MultiMeshInstance3D`, which is the
choice that keeps each tree selectable and diffable. 989 trees at 56 fps is fine for a desktop
target. The budget constant is the tripwire: if a later unit wants denser woods, that is the
number that says whether to switch the forest bulk to a MultiMesh.

`client/tests/test_world_map.gd` proves the layout invariants headlessly: three `Center`
markers 140 to 175 u apart and at least 85 u from `Roads/Hub`, every `Node3D` inside +-128, no
two House footprints overlapping (rectangles from `metadata/footprint` and the house yaw), no
House within its half-diagonal plus 2 u of a spoke, no forest tree within 4 u of a spoke, at
least 600 forest instances, and a 256 x 256 ground. `client/tests/world_map_probe.tscn` renders
the real scene windowed, saves an aerial and four ground-level shots, and asserts the aerial
shows roof-red over each town centre and dirt-brown on the Northmere road 9 u out of the hub,
against a sky-box control that must read zero of both.

**Walk-through buildings are accepted until a navmesh unit.** The server paths in a straight
line and knows nothing of houses, so a player walks through walls. The house footprints the
world-map test reads are the obstacle list that unit needs, and the generator is where to emit
them.

**Seeds stay on the Northmere road near the hub.** Join spawn is (0, 0). The seeded tree is at
(5, 0). Practice dummies and the quest giver sit within a few units of origin. Class-kit ground
seeds start at (1, 2). Plaza centres are the natural respawn points once towns mean something.

**Follow-ups, none owned yet.** The nature kit ships no water and the village kit's free cut
ships no well or stall, so the plazas are bare brick; `Wall_Arch` and
`Stairs_Exterior_Straight` are staged and unused for whoever dresses them.
