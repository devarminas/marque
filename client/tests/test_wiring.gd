extends Node3D

## The M0 milestone, asserted: network state drives avatars, avatars walk their
## paths, and a ground click moves the player who clicked.
##
## The thing under test is [code]main.tscn[/code] itself, instanced once per
## client. The clients therefore share one [World3D]: harmless here, since all
## four grounds are coincident planes, but unhandled input reaches every
## client's picker, so all pickers but the clicking one are switched off.
##
## [b]It must run after [code]test_interop.gd[/code][/b], which asserts on
## sequentially assigned ids and on a world holding only its own clients.

const URL_ENV := "MARQUE_WS_URL"

## Frame cap for the live half (NOTES.md, "Godot authoring traps": headless
## Godot runs uncapped).
const MAX_FPS := 30

const WAIT_FRAMES := 240

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const CameraRigScript := preload("res://scripts/camera_rig.gd")
const Assertions := preload("res://tests/assertions.gd")

const EXACT_EPSILON := 0.002
const SEGMENT_EPSILON := 0.01

## How far two clients' opinions of one walker may differ, in world units. Two
## ticks of travel: 150ms at 3.0 units per second, twice.
const CLOCK_SKEW_TOLERANCE := 0.95

## Where the scripted click lands, in fractions of the viewport. It must miss
## every opaque panel the UI can have open at once;
## [method _test_the_scripted_click_misses_the_opaque_panel] and
## [method _test_the_scripted_click_misses_an_open_equipment_panel] are the only
## guards on that (NOTES.md, "Godot authoring traps").
const CLICK_AT := Vector2(0.30, 0.88)
const MIN_WALK_DISTANCE := 3.0

const SAMPLE_GAP_MSEC := 600
const FIRST_SAMPLE_MSEC := 400

const PATH_SPEED := 3.0


## One client: an instance of `main.tscn` and everything it has heard.
##
## An inner class cannot see the outer script's constants, so its preloads are
## repeated rather than shared.
class Client:
	extends RefCounted

	const MainScene := preload("res://scenes/main.tscn")
	const SessionScript := preload("res://scripts/session.gd")
	const NetClientScript := preload("res://scripts/net_client.gd")
	const GroundPickerScript := preload("res://scripts/ground_picker.gd")
	const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
	const CameraRigScript := preload("res://scripts/camera_rig.gd")
	const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
	const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")

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
	var equipment: EquipmentPanelScript

	var paths: Array[Dictionary] = []
	var clicks: Array[Vector2] = []
	var joins := 0
	var inventories := 0
	var reconnect_delays: Array[int] = []
	var identity_losses: Array[Dictionary] = []
	var resumes := 0

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
		equipment = root.get_node("UI/EquipmentPanel") as EquipmentPanelScript
		root.name = "Client" + label
		session.joined.connect(_on_joined)
		session.move_to_requested.connect(_on_move_to_requested)
		session.reconnect_scheduled.connect(_on_reconnect_scheduled)
		session.resumed.connect(_on_resumed)
		session.identity_lost.connect(_on_identity_lost)
		net.path_assigned.connect(_on_path_assigned)
		net.inventory_changed.connect(_on_inventory_changed)

	func _on_joined(_you: int) -> void:
		joins += 1

	func _on_reconnect_scheduled(delay_msec: int) -> void:
		reconnect_delays.append(delay_msec)

	func _on_resumed(_you: int) -> void:
		resumes += 1

	func _on_identity_lost(was: int, now: int) -> void:
		identity_losses.append({"was": was, "now": now})

	func _on_inventory_changed(
		_size: int, _slot_indices: PackedInt32Array, _slot_kinds: PackedStringArray
	) -> void:
		inventories += 1

	func _on_move_to_requested(x: float, z: float) -> void:
		clicks.append(Vector2(x, z))

	func _on_path_assigned(
		id: int, start_tick: int, points: PackedVector2Array, speed: float
	) -> void:
		paths.append({"id": id, "start_tick": start_tick, "points": points, "speed": speed})

	func paths_for(id: int) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for path in paths:
			if int(path["id"]) == id:
				out.append(path)
		return out

	## Ground-plane position, or null when this client has no body for them.
	func ground_of(id: int) -> Variant:
		var avatar: PlayerAvatarScript = session.avatar_for(id)
		if avatar == null:
			return null
		return Vector2(avatar.position.x, avatar.position.z)

	## Hands one frame to this client's decoder as if it had arrived on the
	## socket.
	func feed(text: String) -> void:
		net.ingest_text_frame(text)


@onready var _clients_node: Node3D = $Clients

var _assertions := Assertions.new()
var _finished := false
var _restore_max_fps := 0
var _frames := 0
var _live_clients: Array[Client] = []


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _process(_delta: float) -> void:
	_frames += 1


func _ready() -> void:
	# NOTES.md, "Godot authoring traps": a raycast needs the physics space to
	# have stepped at least once.
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
		client.session.close()
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
	# Leaves the panel drawn, which the two click tests below depend on.
	await _test_the_scripted_click_misses_the_opaque_panel(client)
	await _test_the_scripted_click_misses_an_open_equipment_panel(client)
	await _test_a_click_becomes_an_intent(client)
	await _test_a_dead_url_backs_off_without_freeing_bodies(client)
	await _test_a_refused_url_backs_off_without_freeing_bodies(client)

	# Freed before the live half exists, so its picker cannot see the live
	# half's clicks and its socket cannot join the live half's world.
	client.root.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


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


## PROTOCOL.md, "Ordering and the join race".
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
	# 6.0 units at 3.0 u/s is 13.33 ticks of 150ms.
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


## PROTOCOL.md, `path`: a halted player gets no path replay on a join.
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

	for _frame in 10:
		await get_tree().process_frame
	_check_ground(
		client, 5, Vector2(-7.5, 11.25), "the halted body is still where welcome put it"
	)
	_check_ground(client, 1, Vector2(2.0, 2.0), "and so is ours")

	client.feed('{"path":{"id":5,"start_tick":301,"points":[[3.5,-1.25]],"speed":3.0}}')
	await get_tree().process_frame
	_check_ground(client, 5, Vector2(3.5, -1.25), "a one-element halt path holds at its point")


## The inventory panel is opaque, and [constant CLICK_AT] has to miss it.
func _test_the_scripted_click_misses_the_opaque_panel(client: Client) -> void:
	client.feed('{"inventory":{"size":28,"slots":[]}}')
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


## [b]M3b's geometry guard.[/b] The player can have the inventory and the
## equipment panel open at the same time, and [constant CLICK_AT] has to miss
## both of them at once.
##
## Two opaque panels are not one problem twice. At the 64x64 headless viewport
## each is wider than the whole screen (NOTES.md, "Godot authoring traps"), so
## the free area is not either panel's leftovers but the intersection of them,
## and an equipment panel anchored anywhere but the bottom-left closes that
## intersection completely and leaves this suite with no world to click.
##
## Run with the inventory panel already drawn by the test above, so what is
## measured here is the state a player is actually in with both open.
func _test_the_scripted_click_misses_an_open_equipment_panel(client: Client) -> void:
	client.equipment.toggle()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(client.equipment.visible, "the equipment panel opens")
	_check(client.panel.visible, "with the inventory panel still open beside it")

	var screen := client.camera.get_viewport().get_visible_rect()
	var equipment_rect := client.equipment.get_global_rect()
	print("WIRING equipment rect %s in viewport %s" % [equipment_rect, screen.size])

	var scripted := screen.size * CLICK_AT
	_check(
		not equipment_rect.has_point(scripted),
		"the scripted click %v is outside the equipment panel %s"
		% [scripted, equipment_rect],
	)
	_check(
		not client.panel.get_global_rect().has_point(scripted),
		"and still outside the inventory panel, so both can be open at once",
	)

	client.equipment.toggle()
	await get_tree().process_frame
	_check(not client.equipment.visible, "and it closes again for the tests below")


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


func _test_a_dead_url_backs_off_without_freeing_bodies(client: Client) -> void:
	print("== dead URL backs off without freeing bodies ==")
	_check(
		SessionScript.reconnect_backoff_msec(0) == 500
		and SessionScript.reconnect_backoff_msec(1) == 1000
		and SessionScript.reconnect_backoff_msec(2) == 2000
		and SessionScript.reconnect_backoff_msec(3) == 4000
		and SessionScript.reconnect_backoff_msec(4) == 5000
		and SessionScript.reconnect_backoff_msec(5) == 5000,
		"backoff is 0.5, 1, 2, 4, 5, 5 s",
	)
	var bodies_before := client.session.known_ids()
	var remotes_before := client.remote_players.get_child_count()
	_check(
		bodies_before == [1, 5] and remotes_before == 1,
		"the second welcome's bodies are still here before the dead URL, got %s / %d"
		% [bodies_before, remotes_before],
	)

	var restore_fps := Engine.max_fps
	Engine.max_fps = 3
	client.reconnect_delays.clear()
	client.session.connect_to_server("ws://")

	var deadline := Time.get_ticks_msec() + 25000
	var seen := 0
	while client.reconnect_delays.size() < 5 and Time.get_ticks_msec() < deadline:
		if client.reconnect_delays.size() > seen:
			seen = client.reconnect_delays.size()
			_check(
				client.session.known_ids() == bodies_before,
				"bodies stay drawn after reconnect wait %d, got %s"
				% [seen, client.session.known_ids()],
			)
			_check(
				client.remote_players.get_child_count() == remotes_before,
				"remote bodies are not freed after reconnect wait %d, got %d"
				% [seen, client.remote_players.get_child_count()],
			)
		await get_tree().process_frame

	Engine.max_fps = restore_fps
	client.session.close()

	_check(
		client.reconnect_delays == [500, 1000, 2000, 4000, 5000],
		"dead URL delays are 0.5, 1, 2, 4, 5 s then the 5 s cap, got %s"
		% [client.reconnect_delays],
	)
	_check(
		client.session.known_ids() == bodies_before,
		"and the bodies are still here after the last attempt, got %s"
		% [client.session.known_ids()],
	)


func _test_a_refused_url_backs_off_without_freeing_bodies(client: Client) -> void:
	print("== refused well-formed URL backs off without freeing bodies ==")
	var bodies_before := client.session.known_ids()
	var remotes_before := client.remote_players.get_child_count()
	_check(
		bodies_before == [1, 5] and remotes_before == 1,
		"the second welcome's bodies are still here before the refused URL, got %s / %d"
		% [bodies_before, remotes_before],
	)

	var restore_fps := Engine.max_fps
	Engine.max_fps = 3
	client.reconnect_delays.clear()
	var status := client.session.connect_to_server("ws://127.0.0.1:1/ws")
	_check(status == OK, "a well-formed refused URL starts connecting (status %d)" % status)

	var deadline := (
		Time.get_ticks_msec()
		+ NetClientScript.CONNECT_TIMEOUT_MSEC * 3
		+ SessionScript.reconnect_backoff_msec(0)
		+ SessionScript.reconnect_backoff_msec(1)
		+ 4000
	)
	var seen := 0
	while client.reconnect_delays.size() < 3 and Time.get_ticks_msec() < deadline:
		if client.reconnect_delays.size() > seen:
			seen = client.reconnect_delays.size()
			_check(
				client.session.known_ids() == bodies_before,
				"bodies stay drawn after refused-URL wait %d, got %s"
				% [seen, client.session.known_ids()],
			)
			_check(
				client.remote_players.get_child_count() == remotes_before,
				"remote bodies are not freed after refused-URL wait %d, got %d"
				% [seen, client.remote_players.get_child_count()],
			)
		await get_tree().process_frame

	Engine.max_fps = restore_fps
	client.session.close()

	_check(
		client.reconnect_delays == [500, 1000, 2000],
		"refused URL delays continue 0.5, 1, 2 s, got %s" % [client.reconnect_delays],
	)
	_check(
		client.session.known_ids() == bodies_before,
		"and the bodies are still here after the refused-URL attempts, got %s"
		% [client.session.known_ids()],
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
	var arrived: bool = await _wait_until(
		func() -> bool: return _is_idle(a, a_id) and _is_idle(b, a_id) and _is_idle(c, a_id),
		"every client to see A finish walking",
	)
	if not arrived:
		return
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
	# Asserted with no waiting in between, on purpose (PROTOCOL.md, `path`).
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
	d.session.close()
	if await _wait_until(
		func() -> bool: return a.session.avatar_for(d_id) == null, "A to drop D's body"
	):
		_check(a.session.avatar_for(d_id) == null, "a despawn removes the body it names")
		_check(
			a.session.avatar_for(a.session.own_id()) != null,
			"and leaves every other body standing",
		)

	await _test_abandoned_session_resumes_itself(url, a, b)
	await _test_stale_token_joins_as_someone_else(url)


func _test_abandoned_session_resumes_itself(url: String, a: Client, b: Client) -> void:
	print("== abandoned session resumes itself ==")
	var a_id := a.session.own_id()
	var b_id := b.session.own_id()
	var joins_before := a.joins
	var inventories_before := a.inventories
	_check(a.session.session_token() != "", "A holds a session token")
	_check(a.session.avatar_for(b_id) != null, "A already has a body for B")

	a.net.abandon()
	_check(not a.net.is_open(), "A's socket is not open after abandon")
	_check(
		a.session.avatar_for(b_id) != null
		and a.remote_players.get_child_count() >= 1,
		"B's body stays under RemotePlayers while A is frozen",
	)

	if not await _wait_until_msec(
		func() -> bool: return a.resumes >= 1 and a.joins > joins_before,
		"A to resume",
		2000,
	):
		return
	_check(a.session.own_id() == a_id, "A came back as itself (%d)" % a_id)
	_check(
		a.session.avatar_for(b_id) != null and a.remote_players.get_child_count() >= 1,
		"B is still under RemotePlayers after resume",
	)
	if await _wait_until(
		func() -> bool: return a.inventories > inventories_before, "A's inventory to follow"
	):
		_check(
			a.inventories > inventories_before and a.panel.slot_count() > 0,
			"inventory was cleared and refilled, now %d slot(s)" % a.panel.slot_count(),
		)
	_check(b.session.avatar_for(a_id) != null, "B kept A's body; a resume is not a spawn")


func _test_stale_token_joins_as_someone_else(url: String) -> void:
	print("== clean close then stale token ==")
	var g := await _join(url, "G")
	if g == null:
		return
	var old_id := g.session.own_id()
	var token := g.session.session_token()
	_check(old_id != 0 and token != "", "G joined with a token")
	g.session.close()
	if not await _wait_until(
		func() -> bool: return not g.net.is_open(), "G's close frame to finish"
	):
		return

	var status := g.session.connect_to_server(NetClientScript.url_with_session(url, token))
	_check(status == OK, "G starts reconnecting with the stale token (status %d)" % status)
	if not await _wait_until(
		func() -> bool: return not g.identity_losses.is_empty(), "identity lost"
	):
		return
	_check(g.session.own_id() != old_id, "stale token is a new own_id(), got %d" % g.session.own_id())
	_check(
		int(g.identity_losses[0]["was"]) == old_id
		and int(g.identity_losses[0]["now"]) == g.session.own_id(),
		"and the session logged identity lost (%s)" % [g.identity_losses[0]],
	)
	print(
		"WIRING IDENTITY LOST: was %d now %d"
		% [old_id, g.session.own_id()]
	)


## Samples one walker on two clients at the same instant. Returns the watching
## client's opinion, or null when it has none.
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


## Returns the ground point the picker resolved, or null.
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


## Presses and releases the left button at a viewport position. Both, so that a
## press landing on the panel cannot leave it holding mouse focus for the next.
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


func _wait_msec(duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _wait_until_msec(predicate: Callable, what: String, budget_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + budget_msec
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	if predicate.call():
		return true
	_check(false, "timed out after %d ms waiting for %s" % [budget_msec, what])
	return false


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
