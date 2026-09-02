extends Node3D

## The M0 milestone, asserted: network state drives avatars, avatars walk their
## paths, and a ground click moves the player who clicked.
##
## The thing under test is [code]main.tscn[/code] itself, instanced once per
## client, so every assertion here is about the scene the game ships rather than
## about a rig assembled for the occasion. Instancing it more than once is what a
## multi-client test costs: the count is genuine runtime information, which is
## the case CLAUDE.md's scene-authoring rule allows a script to build.
##
## The clients share one [World3D], because they are children of one tree. That
## is harmless for everything asserted here — all four grounds are coincident
## planes, so a ray through any of them meets the same point — and it costs one
## piece of bookkeeping: unhandled input reaches every client's picker, so all
## pickers but the clicking one are switched off before a click is pushed.
##
## Two halves, like [code]test_interop.gd[/code].
##
## The [b]offline[/b] half needs no server and always runs. Frames are handed to
## the client by hand, which is the only way to reach the shapes a conforming
## server will not produce on demand: a `spawn` for an id already known, a
## `despawn` and a `path` for an id that was never announced, a one-element halt
## path.
##
## The [b]live[/b] half needs a real `marqued` named by [constant URL_ENV] and
## skips loudly without one. It is where the milestone sentence is actually
## proven: two clients connected to one server, one clicks, and the other watches
## the avatar move.
##
## [b]It must run after [code]test_interop.gd[/code].[/b] That suite asserts on
## sequentially assigned player ids and on a world containing only its own
## clients, so anything that connects first breaks it. This suite makes the
## opposite assumption on purpose: it learns every id from a `welcome` and never
## assumes the world is empty, so leftovers from the suite before it cost it
## nothing.

## Names the environment variable carrying the websocket URL, as
## [code]test_interop.gd[/code] does. `scripts/interop_test.ps1` sets it.
const URL_ENV := "MARQUE_WS_URL"

## Frame cap held for the duration of the live half. Headless Godot runs
## uncapped, so without this a fast machine burns the runner's frame budget
## waiting on one handshake (NOTES.md, "Godot authoring traps").
const MAX_FPS := 60

## Upper bound on any single wait. About four seconds at [constant MAX_FPS].
const WAIT_FRAMES := 240

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const CameraRigScript := preload("res://scripts/camera_rig.gd")
const Assertions := preload("res://tests/assertions.gd")

## Tolerance for a position that should be exact: a walker holding at the final
## point of its polyline, or a body teleported to a stated coordinate. Absorbs
## the float32 round trip and nothing else.
const EXACT_EPSILON := 0.002

## How far a body may sit off the straight line it is walking. It is a lerp
## between two points, so this is float noise, not slack.
const SEGMENT_EPSILON := 0.01

## How far two clients' opinions of one walker may differ, in world units.
##
## Each client anchors its own clock from its own `welcome` and evaluates the
## walker at an integer tick, so two clients one tick apart place the same
## walker exactly one tick of travel apart: 150ms at 3.0 units per second is
## 0.45. This allows two ticks and no more, which is still a twentieth of the
## walk being asserted.
const CLOCK_SKEW_TOLERANCE := 0.95

## Where on the screen the scripted click lands, in fractions of the viewport.
##
## Off centre in both axes so the resulting walk is long enough to sample twice
## while it is still under way. With the authored camera framing this resolves
## to roughly seven world units from the spawn point; the walk is asserted to be
## at least [constant MIN_WALK_DISTANCE] so that a change to the framing fails
## here loudly instead of quietly making the walk too short to measure.
##
## [b]It must also miss the inventory panel, which is opaque (M1k).[/b] The
## headless viewport is 64x64 (NOTES.md) and the panel measures 240x432 anchored
## 16px off the bottom-right corner, so it covers (0, 0) to (48, 48) and leaves
## only a 16px strip along the right and bottom edges. This lands at (19.2,
## 56.32), in the bottom strip, 8px clear of the panel and 7px clear of the
## viewport edge. At the shipped 1280x720 it is (384, 633.6) against a panel
## occupying (1024, 272) to (1264, 704), which misses by a wider margin still.
##
## [b]Of those two margins only the panel's is load-bearing.[/b] Probed against
## 4.7.2 on the 64x64 viewport: [method Viewport.push_input] delivers a press
## whatever its position, and the picker fires exactly when the point is off the
## panel and the ray meets ground — the viewport rect never enters into it.
## (19.2, 70), (70, 30) and (19.2, 500) all sit outside the viewport and all
## reached the picker; (-10, 30) and (-50, 40) sit outside it too and were
## swallowed, because the panel's rect extends past the viewport and they are
## inside it. So a point outside the viewport would still walk the player, and
## would still satisfy a test that only counted intents. Staying inside is about
## clicking where a player's mouse could actually be, not about the click
## surviving the trip.
##
## The old value, (0.30, 0.72), landed at (19.2, 46.08) — inside the panel, and
## it reached the world only because the chrome was click-through. That is the
## coupling M1k inherited: making the panel opaque and moving this constant are
## one change. [method _test_the_scripted_click_misses_the_opaque_panel] is what
## stops the two drifting apart again.
const CLICK_AT := Vector2(0.30, 0.88)
const MIN_WALK_DISTANCE := 3.0

## Milliseconds between the two samples of a walk in progress. At 3.0 units per
## second this is about 1.8 units of travel, which is far outside any tolerance
## here.
const SAMPLE_GAP_MSEC := 600
## Milliseconds to let the walk get under way before the first sample.
const FIRST_SAMPLE_MSEC := 400

## Speed used by the offline half's hand-written paths, in world units per
## second. It matches the server's only so that the arithmetic at the call site
## reads the same as the live half's; nothing offline talks to a server.
const PATH_SPEED := 3.0


## One client: an instance of `main.tscn` and everything it has heard.
##
## An inner class is its own scope and cannot see the outer script's constants,
## so the preloads it needs are repeated here.
class Client:
	extends RefCounted

	const MainScene := preload("res://scenes/main.tscn")
	const SessionScript := preload("res://scripts/session.gd")
	const NetClientScript := preload("res://scripts/net_client.gd")
	const GroundPickerScript := preload("res://scripts/ground_picker.gd")
	const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
	const CameraRigScript := preload("res://scripts/camera_rig.gd")
	const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")

	var label: String
	var root: Node3D
	var session: SessionScript
	var net: NetClientScript
	var picker: GroundPickerScript
	var rig: CameraRigScript
	var camera: Camera3D
	var local_body: Node3D
	var remote_players: Node3D
	var panel: InventoryPanelScript

	var paths: Array[Dictionary] = []
	var clicks: Array[Vector2] = []
	var joins := 0

	func _init(client_label: String) -> void:
		label = client_label
		root = MainScene.instantiate() as Node3D
		session = root.get_node("Session") as SessionScript
		net = root.get_node("Session/Net") as NetClientScript
		picker = root.get_node("GroundPicker") as GroundPickerScript
		rig = root.get_node("CameraRig") as CameraRigScript
		camera = root.get_node("CameraRig/Camera3D") as Camera3D
		local_body = root.get_node("Player") as Node3D
		remote_players = root.get_node("RemotePlayers") as Node3D
		panel = root.get_node("UI/InventoryPanel") as InventoryPanelScript
		root.name = "Client" + label
		session.joined.connect(_on_joined)
		session.move_to_requested.connect(_on_move_to_requested)
		net.path_assigned.connect(_on_path_assigned)

	func _on_joined(_you: int) -> void:
		joins += 1

	func _on_move_to_requested(x: float, z: float) -> void:
		clicks.append(Vector2(x, z))

	func _on_path_assigned(
		id: int, start_tick: int, points: PackedVector2Array, speed: float
	) -> void:
		paths.append({"id": id, "start_tick": start_tick, "points": points, "speed": speed})

	## Every path this client heard about one player, oldest first.
	func paths_for(id: int) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for path in paths:
			if int(path["id"]) == id:
				out.append(path)
		return out

	## Where this client currently draws player [param id], ground-plane, or
	## null when it has no body for them.
	func ground_of(id: int) -> Variant:
		var avatar: PlayerAvatarScript = session.avatar_for(id)
		if avatar == null:
			return null
		return Vector2(avatar.position.x, avatar.position.z)

	## Hands one frame to this client's decoder as if it had arrived on the
	## socket. The offline half's only input.
	func feed(text: String) -> void:
		net.ingest_text_frame(text)


@onready var _clients_node: Node3D = $Clients

var _assertions := Assertions.new()
var _finished := false
var _restore_max_fps := 0
var _frames := 0
var _live_clients: Array[Client] = []


## Suite contract, polled by `run_tests.gd`. Reports; never quits.
func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _process(_delta: float) -> void:
	_frames += 1


func _ready() -> void:
	# A ray query before the physics space has stepped finds nothing, and the
	# failure looks exactly like a broken raycast (NOTES.md).
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("== wiring: appliers, no server ==")
	await _test_appliers_without_a_server()

	var url := OS.get_environment(URL_ENV)
	if url.is_empty():
		print(
			"WIRING SKIPPED: %s is unset; run scripts/interop_test.ps1 to exercise it" % URL_ENV
		)
		_finished = true
		return

	print("== wiring: live against %s ==" % url)
	_restore_max_fps = Engine.max_fps
	Engine.max_fps = MAX_FPS

	await _run_live(url)

	Engine.max_fps = _restore_max_fps
	for client in _live_clients:
		client.net.close()
	print(
		"WIRING RAN: %d assertions, %d failed, %d frames"
		% [_assertions.assertion_count, _assertions.failures.size(), _frames]
	)
	_finished = true


# --------------------------------------------------------------------------
# Offline half: every applier, driven by hand-written frames.
# --------------------------------------------------------------------------


func _test_appliers_without_a_server() -> void:
	var client := Client.new("Offline")
	_clients_node.add_child(client.root)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_test_scene_wiring(client)
	_test_welcome_builds_the_world(client)
	_test_spawn_is_idempotent(client)
	_test_unknown_ids_are_ignored(client)
	_test_paths_reach_the_right_body(client)
	await _test_a_halted_player_is_placed_and_never_waited_for(client)
	# Leaves the panel drawn, on purpose: the click test below then proves the
	# world is reachable in the configuration that ships, rather than in one
	# where the panel happens to be hidden.
	await _test_the_scripted_click_misses_the_opaque_panel(client)
	await _test_a_click_becomes_an_intent(client)

	# Freed before the live half exists, so its picker cannot see the live
	# half's clicks and its socket cannot join the live half's world.
	client.root.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


## The scene has to hand the session everything it needs, and the camera has to
## follow the body the session will drive.
func _test_scene_wiring(client: Client) -> void:
	_check(client.session != null, "main.tscn authors a Session node")
	_check(client.net != null, "the Session owns a net_client.gd node in the scene")
	_check(
		client.local_body != null and client.local_body is PlayerAvatarScript,
		"the authored Player is a player_avatar.tscn instance",
	)
	_check(
		client.rig != null and client.rig.target == client.local_body,
		"CameraRig follows the same node the session drives",
	)
	_check(client.remote_players.get_child_count() == 0, "RemotePlayers starts empty")
	_check(not client.session.has_joined(), "a session has not joined before welcome")
	_check(client.session.known_ids().is_empty(), "and knows about nobody")
	_check(
		not client.session.tick_clock().is_anchored(),
		"and its clock is unanchored until welcome anchors it",
	)


## `welcome` is the whole world. Everyone listed gets a body, including us.
func _test_welcome_builds_the_world(client: Client) -> void:
	client.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":142,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0},{"id":2,"x":5.0,"z":-3.0}]}}'
	)
	_check(client.session.has_joined(), "welcome joins the session")
	_check(client.joins == 1, "the joined signal fires once, got %d" % client.joins)
	_check(client.session.own_id() == 1, "own_id is welcome.you")
	_check(
		client.session.known_ids() == [1, 2],
		"both listed players get a body, got %s" % [client.session.known_ids()],
	)
	_check(
		client.session.avatar_for(1) == client.local_body,
		"our own body is the authored Player node, not a new one",
	)
	_check(
		client.remote_players.get_child_count() == 1,
		"exactly one remote body was instanced, got %d" % client.remote_players.get_child_count(),
	)
	var other: PlayerAvatarScript = client.session.avatar_for(2)
	_check(
		other != null and other.get_parent() == client.remote_players,
		"the remote body hangs off the RemotePlayers container",
	)
	_check_ground(client, 1, Vector2(0.0, 0.0), "our body sits at the position welcome states")
	_check_ground(client, 2, Vector2(5.0, -3.0), "the remote body sits where welcome states")

	var clock := client.session.tick_clock()
	_check(clock.is_anchored(), "welcome anchors the clock")
	_check(clock.tick_ms() == 150, "the clock takes tick_ms from welcome, got %d" % clock.tick_ms())
	_check(
		clock.estimated_tick() >= 142,
		"the estimate starts at welcome.tick, got %d" % clock.estimated_tick(),
	)


## PROTOCOL.md, "Ordering and the join race": a spawn for an id already known
## replaces rather than adding a second avatar.
func _test_spawn_is_idempotent(client: Client) -> void:
	client.feed('{"spawn":{"id":3,"x":1.0,"z":2.0}}')
	_check(client.session.known_ids() == [1, 2, 3], "a spawn adds a body")
	_check(
		client.remote_players.get_child_count() == 2,
		"two remote bodies now, got %d" % client.remote_players.get_child_count(),
	)
	_check_ground(client, 3, Vector2(1.0, 2.0), "the spawned body is at the spawn position")

	client.feed('{"spawn":{"id":3,"x":-4.0,"z":8.0}}')
	_check(
		client.remote_players.get_child_count() == 2,
		"a repeated spawn replaces rather than doubling, got %d children"
		% client.remote_players.get_child_count(),
	)
	_check(client.session.known_ids() == [1, 2, 3], "and leaves the id set alone")
	_check_ground(client, 3, Vector2(-4.0, 8.0), "the replacement is at the new position")


## An id nobody announced is logged and ignored, never an error and never a
## reason to stop.
func _test_unknown_ids_are_ignored(client: Client) -> void:
	var before := client.session.known_ids()
	client.feed('{"despawn":{"id":99}}')
	_check(client.session.known_ids() == before, "a despawn for an unknown id changes nothing")
	client.feed('{"path":{"id":99,"start_tick":142,"points":[[0,0],[1,1]],"speed":3.0}}')
	_check(client.session.known_ids() == before, "a path for an unknown id changes nothing")
	_check(
		client.remote_players.get_child_count() == 2,
		"and neither invents a body, got %d" % client.remote_players.get_child_count(),
	)

	client.feed('{"despawn":{"id":3}}')
	_check(client.session.known_ids() == [1, 2], "a despawn for a known id drops the body")
	_check(
		client.remote_players.get_child_count() == 1,
		"the node leaves the tree in the same frame, got %d children"
		% client.remote_players.get_child_count(),
	)
	_check(client.session.avatar_for(3) == null, "and the session forgets it")


## A path lands on the body it names and nowhere else.
func _test_paths_reach_the_right_body(client: Client) -> void:
	var start_tick := 200
	client.feed(
		'{"path":{"id":2,"start_tick":%d,"points":[[5.0,-3.0],[5.0,3.0]],"speed":%f}}'
		% [start_tick, PATH_SPEED]
	)
	var walker: PlayerAvatarScript = client.session.avatar_for(2)
	_check(walker != null, "the named body exists")
	if walker == null:
		return
	# 6.0 units at 3.0 u/s is 2.0s, which is 13.33 ticks of 150ms. So the walk
	# is unfinished at tick 13 and finished at tick 14.
	_check(
		not walker.is_idle_at_tick(start_tick),
		"the body has a path to walk at the tick it starts",
	)
	_check(
		not walker.is_idle_at_tick(start_tick + 13),
		"and is still walking one tick short of the end",
	)
	_check(walker.is_idle_at_tick(start_tick + 14), "and has arrived one tick past it")

	var ours: PlayerAvatarScript = client.session.avatar_for(1)
	_check(
		ours != null and ours.is_idle_at_tick(start_tick + 14),
		"the path did not leak onto our own body",
	)


## PROTOCOL.md, `path`: a halted player gets no path replay on a join. They are
## a position in `welcome.players` and nothing else, ever.
##
## The hang this rules out is a client that expects one `path` per listed player.
## Here the second listed player is never given one, and the assertion is that
## the body is placed and stays placed regardless.
func _test_a_halted_player_is_placed_and_never_waited_for(client: Client) -> void:
	client.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":300,'
		+ '"players":[{"id":1,"x":2.0,"z":2.0},{"id":5,"x":-7.5,"z":11.25}]}}'
	)
	_check(client.session.has_joined(), "a second welcome rebuilds rather than hanging")
	_check(
		client.session.known_ids() == [1, 5],
		"the world is exactly what the new welcome states, got %s"
		% [client.session.known_ids()],
	)
	_check(
		client.remote_players.get_child_count() == 1,
		"the bodies from the previous welcome are gone, got %d children"
		% client.remote_players.get_child_count(),
	)
	var halted: PlayerAvatarScript = client.session.avatar_for(5)
	_check(halted != null, "the halted player has a body immediately, with no path to wait for")
	if halted == null:
		return
	_check(
		halted.is_idle_at_tick(300) and halted.is_idle_at_tick(9000),
		"a body with no path is idle at every tick",
	)

	# Several frames of the clock actually running. A body driven by a walker it
	# does not have would drift or snap to the origin here.
	for _frame in 10:
		await get_tree().process_frame
	_check_ground(
		client, 5, Vector2(-7.5, 11.25), "the halted body is still where welcome put it"
	)
	_check_ground(client, 1, Vector2(2.0, 2.0), "and so is ours")

	# One point means halt here, and the walker holds that point at every tick.
	client.feed('{"path":{"id":5,"start_tick":301,"points":[[3.5,-1.25]],"speed":3.0}}')
	await get_tree().process_frame
	_check_ground(client, 5, Vector2(3.5, -1.25), "a one-element halt path holds at its point")


## The inventory panel is opaque (M1k), and [constant CLICK_AT] is the constant
## that has to miss it.
##
## [b]Both halves are needed and neither is enough.[/b] "A click on the panel
## produced no `move_to`" also holds on a build where the click landed outside
## the viewport and reached nothing at all, which is why the rect is measured
## and printed, the scripted click is asserted to be on screen, and the chrome
## point is asserted to be on screen and inside the panel before it is clicked.
## A test that only counts intents cannot tell an opaque panel from a click that
## went nowhere.
func _test_the_scripted_click_misses_the_opaque_panel(client: Client) -> void:
	client.feed('{"inventory":{"size":28,"slots":[{"slot":0,"kind":"acorn"}]}}')
	# A rebuilt grid has not sorted its children yet, and a widget with no rect
	# is a rect that every point misses.
	await get_tree().process_frame
	await get_tree().process_frame
	_check(client.panel.visible, "an inventory frame draws the panel")
	_check(
		client.panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and the panel stops clicks rather than letting them through, got filter %d"
		% client.panel.mouse_filter,
	)

	var viewport := client.camera.get_viewport()
	var screen := viewport.get_visible_rect()
	var panel_rect := client.panel.get_global_rect()
	print("WIRING panel rect %s in viewport %s" % [panel_rect, screen.size])

	var scripted := screen.size * CLICK_AT
	_check(
		screen.has_point(scripted),
		"the scripted click %v is inside the viewport %s" % [scripted, screen.size],
	)
	_check(
		not panel_rect.has_point(scripted),
		"and outside the panel %s, which would otherwise swallow it" % [panel_rect],
	)

	var chrome: Variant = _chrome_point(client, panel_rect, screen)
	_check(chrome != null, "the panel draws chrome inside the viewport to click on")
	if chrome == null:
		return
	var at: Vector2 = chrome
	client.clicks.clear()
	_push_left_click(viewport, at)
	await get_tree().process_frame
	_check(
		client.clicks.is_empty(),
		"a click on the panel's chrome at %v walks nobody, got %s" % [at, client.clicks],
	)


## A point inside the panel's drawn rect, inside the viewport, and on no slot
## widget, or null when the panel draws no such point.
##
## Derived rather than written down, because the panel's size comes from the
## theme and the slot metrics, so a literal would go stale the first time either
## moved — and it would go stale [i]silently[/i]: a point that had drifted onto a
## slot still produces no `move_to`, so the assertion above it would still pass
## while testing something else.
static func _chrome_point(client: Client, panel_rect: Rect2, screen: Rect2) -> Variant:
	var slots: Array[Rect2] = []
	for index in client.panel.slot_count():
		var slot := client.panel.slot_at(index)
		if slot != null:
			slots.append(slot.get_global_rect())

	for inset: Vector2 in [Vector2(4, 4), Vector2(4, 20), Vector2(20, 4), Vector2(20, 20)]:
		var candidate := panel_rect.end - inset
		if not screen.has_point(candidate) or not panel_rect.has_point(candidate):
			continue
		var on_slot := false
		for rect in slots:
			if rect.has_point(candidate):
				on_slot = true
				break
		if not on_slot:
			return candidate
	return null


## The click seam, without a socket: a left click on the ground becomes a
## `move_to` intent carrying the coordinate the picker resolved.
func _test_a_click_becomes_an_intent(client: Client) -> void:
	var viewport := client.camera.get_viewport()
	var screen_position := viewport.get_visible_rect().size * CLICK_AT
	var expected: Variant = client.picker.pick_ground(screen_position)
	_check(expected != null, "the scripted click position resolves to a ground point")
	if expected == null:
		return

	client.clicks.clear()
	_push_left_click(viewport, screen_position)
	await get_tree().process_frame

	_check(
		client.clicks.size() == 1,
		"one click produces one move_to intent, got %d" % client.clicks.size(),
	)
	if client.clicks.size() != 1:
		return
	var wanted: Vector2 = expected
	_check(
		client.clicks[0].distance_to(wanted) < EXACT_EPSILON,
		"the intent carries the picked ground point %v, got %v" % [wanted, client.clicks[0]],
	)
	_check(
		wanted.length() > MIN_WALK_DISTANCE,
		"the scripted click is %f units from the spawn point, which must exceed %f"
		% [wanted.length(), MIN_WALK_DISTANCE],
	)


# --------------------------------------------------------------------------
# Live half: real server, real sockets, real walking.
# --------------------------------------------------------------------------


func _run_live(url: String) -> void:
	var a := await _join(url, "A")
	if a == null:
		return
	var b := await _join(url, "B")
	if b == null:
		return

	var a_id := a.session.own_id()
	var b_id := b.session.own_id()
	print("== two clients see each other ==")
	_check(a_id != b_id, "the two clients have different ids (%d, %d)" % [a_id, b_id])
	if not await _wait_until(
		func() -> bool: return a.session.avatar_for(b_id) != null, "A's body for B"
	):
		return
	_check(a.session.avatar_for(b_id) != null, "A has a body for B, learnt from spawn")
	_check(b.session.avatar_for(a_id) != null, "B has a body for A, learnt from welcome")
	_check(
		a.remote_players.get_child_count() >= 1,
		"A instanced B into RemotePlayers, %d child(ren)" % a.remote_players.get_child_count(),
	)

	var origin_variant: Variant = b.ground_of(a_id)
	if origin_variant == null:
		_check(false, "B has no position for A to start from")
		return
	var origin: Vector2 = origin_variant

	print("== A clicks the ground ==")
	var destination_variant: Variant = await _click_ground(a)
	if destination_variant == null:
		return
	var destination: Vector2 = destination_variant
	_check(
		origin.distance_to(destination) > MIN_WALK_DISTANCE,
		"the scripted click is a real walk: %f units from %v to %v"
		% [origin.distance_to(destination), origin, destination],
	)

	if not await _wait_until(
		func() -> bool: return not b.paths_for(a_id).is_empty(), "B's copy of A's path"
	):
		return
	_check(a.paths_for(a_id).size() == 1, "the mover is told its own path")
	_check(b.paths_for(a_id).size() == 1, "and so is everyone else")

	print("== B watches A walk ==")
	await _wait_msec(FIRST_SAMPLE_MSEC)
	var first: Variant = _sample(a, b, a_id, origin, destination, "first sample")
	await _wait_msec(SAMPLE_GAP_MSEC)
	var second: Variant = _sample(a, b, a_id, origin, destination, "second sample")

	if first != null and second != null:
		var one: Vector2 = first
		var two: Vector2 = second
		_check(
			one.distance_to(origin) > 0.2,
			"A had left the spawn point by the first sample (%v vs %v)" % [one, origin],
		)
		_check(
			two.distance_to(one) > 0.5,
			"A moved between the two samples: %v then %v, %f units"
			% [one, two, two.distance_to(one)],
		)
		_check(
			_progress_along(origin, destination, two)
			> _progress_along(origin, destination, one),
			"and moved toward the destination rather than away from it",
		)

	print("== a late joiner renders the walk in progress ==")
	var c := await _join(url, "C")
	if c == null:
		return
	var late: Variant = c.ground_of(a_id)
	var live: Variant = b.ground_of(a_id)
	_check(late != null, "C has a body for A the moment it joins")
	if late != null and live != null:
		var late_here: Vector2 = late
		var live_here: Vector2 = live
		_check(
			c.paths_for(a_id).size() == 1,
			"C learns the walk through one replayed path, got %d" % c.paths_for(a_id).size(),
		)
		var progress := _progress_along(origin, destination, late_here)
		_check(
			progress > 0.0 and progress < 1.0,
			"C draws A partway along the walk, not at either end (t = %f)" % progress,
		)
		_check(
			_distance_to_segment(origin, destination, late_here) < SEGMENT_EPSILON,
			"C draws A on the polyline, at %v" % late_here,
		)
		_check(
			late_here.distance_to(live_here) < CLOCK_SKEW_TOLERANCE,
			"C and B agree about where A is: %v vs %v, %f apart"
			% [late_here, live_here, late_here.distance_to(live_here)],
		)

	print("== A arrives where A clicked ==")
	# Every client, not just one: three independently anchored clocks can be a
	# tick apart, and asserting on one of them the moment it says "arrived"
	# would race the other two by up to 150ms.
	var arrived: bool = await _wait_until(
		func() -> bool: return _is_idle(a, a_id) and _is_idle(b, a_id) and _is_idle(c, a_id),
		"every client to see A finish walking",
	)
	if not arrived:
		return
	# One more frame so every client has drawn the final tick.
	await get_tree().process_frame
	_check_live_ground(b, a_id, destination, EXACT_EPSILON, "B draws A at the clicked point")
	_check_live_ground(
		a, a_id, destination, EXACT_EPSILON, "and A's own body stands on the point A clicked"
	)
	_check_live_ground(c, a_id, destination, EXACT_EPSILON, "and so does the late joiner's")

	print("== joining a world where nobody is walking ==")
	var d := await _join(url, "D")
	if d == null:
		return
	# Asserted the instant the welcome has been applied, with no waiting in
	# between: a client that expected one path per listed player would still be
	# waiting here, and would wait forever (PROTOCOL.md, `path`).
	_check(
		d.session.avatar_for(a_id) != null,
		"a body for the halted player exists as soon as welcome is applied",
	)
	_check(
		d.paths_for(a_id).is_empty(),
		"and no path was replayed for them, got %d" % d.paths_for(a_id).size(),
	)
	_check_live_ground(
		d, a_id, destination, EXACT_EPSILON, "the halted player is drawn where they stopped"
	)
	for _frame in 20:
		await get_tree().process_frame
	_check(
		d.paths_for(a_id).is_empty(), "no path arrives for them later either"
	)
	_check_live_ground(
		d, a_id, destination, EXACT_EPSILON, "and they have not drifted"
	)

	print("== leaving ==")
	var d_id := d.session.own_id()
	d.net.close()
	if await _wait_until(
		func() -> bool: return a.session.avatar_for(d_id) == null, "A to drop D's body"
	):
		_check(a.session.avatar_for(d_id) == null, "a despawn removes the body it names")
		_check(
			a.session.avatar_for(a.session.own_id()) != null,
			"and leaves every other body standing",
		)


## Samples one walker on two clients at the same instant and checks that both
## agree, that both put it on the polyline, and that it is between the ends.
##
## Returns the watching client's opinion, or null when it has none.
func _sample(
	mover: Client,
	watcher: Client,
	id: int,
	origin: Vector2,
	destination: Vector2,
	what: String,
) -> Variant:
	var watched: Variant = watcher.ground_of(id)
	var owned: Variant = mover.ground_of(id)
	_check(watched != null, "%s: the watcher has a body for the walker" % what)
	_check(owned != null, "%s: the mover has a body for itself" % what)
	if watched == null or owned == null:
		return null
	var watched_here: Vector2 = watched
	var owned_here: Vector2 = owned
	_check(
		_distance_to_segment(origin, destination, watched_here) < SEGMENT_EPSILON,
		"%s: the walker is on its polyline, at %v" % [what, watched_here],
	)
	_check(
		watched_here.distance_to(owned_here) < CLOCK_SKEW_TOLERANCE,
		"%s: the mover and the watcher agree, %v vs %v, %f apart"
		% [what, owned_here, watched_here, watched_here.distance_to(owned_here)],
	)
	return watched_here


## Connects one client and waits for its `welcome` to be applied.
func _join(url: String, label: String) -> Client:
	var client := Client.new(label)
	_live_clients.append(client)
	_clients_node.add_child(client.root)
	# Every picker but the clicker's is switched off: the clients share one
	# tree, so unhandled input reaches all of them.
	client.picker.set_process_unhandled_input(false)
	await get_tree().process_frame

	var status := client.session.connect_to_server(url)
	_check(status == OK, "client %s starts connecting (status %d)" % [label, status])
	if status != OK:
		return null
	if not await _wait_until(
		func() -> bool: return client.session.has_joined(), "client %s's welcome" % label
	):
		return null
	return client


## Pushes a real left click through [param client]'s viewport and returns the
## ground point the picker resolved, or null.
func _click_ground(client: Client) -> Variant:
	var viewport := client.camera.get_viewport()
	var screen_position := viewport.get_visible_rect().size * CLICK_AT
	var picked: Variant = client.picker.pick_ground(screen_position)
	_check(picked != null, "the scripted click position resolves to a ground point")
	if picked == null:
		return null

	client.clicks.clear()
	client.picker.set_process_unhandled_input(true)
	_push_left_click(viewport, screen_position)
	await get_tree().process_frame
	client.picker.set_process_unhandled_input(false)

	_check(
		client.clicks.size() == 1,
		"the click produced one intent, got %d" % client.clicks.size(),
	)
	for other in _live_clients:
		if other == client:
			continue
		_check(
			other.clicks.is_empty(),
			"client %s did not also react to the click" % other.label,
		)
	if client.clicks.size() != 1:
		return null
	return client.clicks[0]


func _is_idle(client: Client, id: int) -> bool:
	var avatar: PlayerAvatarScript = client.session.avatar_for(id)
	if avatar == null:
		return false
	return avatar.is_idle_at_tick(client.session.tick_clock().estimated_tick())


## Presses and releases the left button at a viewport position.
##
## [b]The release is not decoration.[/b] The picker acts on the press alone, so
## a press-only helper looks sufficient and is not: a press over a [Control]
## leaves that Control holding the viewport's mouse focus, and where the next
## press goes then depends on an engine re-resolution rule nobody here has
## probed. Since M1k one of the clicks below deliberately lands on the opaque
## panel and the next one deliberately does not, so the sequence would rest on
## that rule. Releasing ends the interaction instead of relying on it.
## `test_interaction.gd`'s `_click_slot` and `pickup_demo.gd` already send both.
static func _push_left_click(viewport: Viewport, screen_position: Vector2) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = screen_position
		viewport.push_input(event)


# --------------------------------------------------------------------------
# Waiting, measuring, reporting.
# --------------------------------------------------------------------------


func _wait_until(predicate: Callable, what: String) -> bool:
	for _frame in WAIT_FRAMES:
		if predicate.call():
			return true
		await get_tree().process_frame
	if predicate.call():
		return true
	_check(false, "timed out after %d frames waiting for %s" % [WAIT_FRAMES, what])
	return false


## Burns frames for a wall-clock interval. Test sequencing, not game logic:
## nothing here derives a position from it.
func _wait_msec(duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _check_ground(client: Client, id: int, expected: Vector2, message: String) -> void:
	var here: Variant = client.ground_of(id)
	if here == null:
		_check(false, "%s (no body for player %d)" % [message, id])
		return
	var actual: Vector2 = here
	_check(
		actual.distance_to(expected) < EXACT_EPSILON,
		"%s (expected %v, got %v)" % [message, expected, actual],
	)


func _check_live_ground(
	client: Client, id: int, expected: Vector2, epsilon: float, message: String
) -> void:
	var here: Variant = client.ground_of(id)
	if here == null:
		_check(false, "%s (no body for player %d)" % [message, id])
		return
	var actual: Vector2 = here
	_check(
		actual.distance_to(expected) < epsilon,
		"%s (expected %v +/- %f, got %v)" % [message, expected, epsilon, actual],
	)


## Where `point` falls along the segment from `from` to `to`, as a fraction.
func _progress_along(from: Vector2, to: Vector2, point: Vector2) -> float:
	var span := to - from
	var length_squared := span.length_squared()
	if length_squared == 0.0:
		return 0.0
	return (point - from).dot(span) / length_squared


func _distance_to_segment(from: Vector2, to: Vector2, point: Vector2) -> float:
	var t := clampf(_progress_along(from, to, point), 0.0, 1.0)
	return point.distance_to(from + (to - from) * t)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
