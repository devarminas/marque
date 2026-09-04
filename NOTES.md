# Game Notes

Game: RuneScape-like point-and-click farming/crafting, multiplayer, persistent inventory.
Codename: Project Marque.

Client is Godot 4.7, GDScript, **3D with an orbiting camera** above and behind the player.
**Forward+ renderer, desktop only.** Browser export is not a goal, so nothing is constrained
by WebGL limits or by download size.
Server is Go 1.27, single authoritative server. Transport is WebSocket carrying JSON.

Settled decisions that are closed to re-litigation live in
[STANDING-ORDERS.md](STANDING-ORDERS.md). This file holds the design detail behind them.

Installed and verified: Godot 4.7.2, Go 1.27.0, git 2.55, gh 2.97.0.

## Headless testing

```bash
godot --headless --path . --script res://tests/run_tests.gd
```

- No rendering server. Logic, physics, signals, resources all run.
- `print()` → stdout. `quit(1)` → exit code. `--quit-after N` bounds runaway loops.
- Test framework: GdUnit4 (check it supports the Godot version before committing).
- Anything visual (shaders, viewport textures) does not work headless.
- Visual checks: game screenshots itself, don't automate the desktop.
  `get_viewport().get_texture().get_image().save_png("user://shot.png")`

## Godot authoring traps

Found the hard way while building the M0c scene. Every one is **silent**: no error, no warning,
just a wrong result surfacing far from its cause. Read this before hand-authoring a `.tscn` or
adding a headless test.

- **`Transform3D(...)` in a `.tscn` takes nine basis floats row-major**, not three axis vectors.
  Writing it as `(basis.x, basis.y, basis.z, origin)` gives you the transpose. A sun authored
  that way pointed at the sky, and the scene still looked lit because sky ambient was doing the
  work. Generate the string instead of hand-writing it:
  `print(var_to_str(Transform3D(Basis.from_euler(...), origin)))`.
- **`@export var camera: Camera3D` needs `node_paths=PackedStringArray("camera")` on the
  `[node]` header.** Without it the assigned `NodePath` resolves to `null`. Nothing warns.
- **Do not put `uid="uid://..."` on `ext_resource` lines.** Resolving them needs
  `.godot/uid_cache.bin`, which only an editor scan writes, and `.godot/` is gitignored. A fresh
  clone prints `invalid UID` warnings and falls back to the path. Reference by path.
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

## Backend — Go

No physics to share with the client, so no reason to run Godot on the server.
The game is a database with a game attached; Go has the ecosystem for that (pgx).

| Piece | What | Owns |
|---|---|---|
| Client | Godot / GDScript | Render, input, interpolation. Zero authority. |
| Server | Go | Tick loop, all state in memory, all validation |
| DB | Postgres | Durable state, written transactionally |
| Transport | WebSocket | Godot `WebSocketPeer` ↔ Go |

- `CLAUDE.md` owns the invariants (intents not facts, client state is a cache, one goroutine
  owns the state). The reason is the dupe section below. Every rule there assumes the server is
  the only writer.
- Shared data (items, recipes, XP tables, map) = JSON in one folder, read by both. One source of truth, two languages.

## Movement — client sends click, server returns polyline

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

- Pathfinding lives only on the server (`CLAUDE.md`), because a client pathfinder is a second
  copy that diverges.
- Client walks the polyline and interpolates → smooth movement regardless of tick rate.
- Cost is one round trip before the character moves. Reads as normal for click-to-move.
- Send waypoints, not per-tick positions.
- Server validates the destination is reachable. Reject unreachable clicks, don't silently snap to nearest.
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

The rule is settled item 4 in `STANDING-ORDERS.md`: 150 ms, one named constant on the server,
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
