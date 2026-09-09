extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const CursorHintScript := preload("res://scripts/cursor_hint.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const Assertions := preload("res://tests/assertions.gd")

const SCRIPTS_DIR := "res://scripts"
const OWNER_PATH := "res://scripts/cursor_hint.gd"
const ASSET_DIR := "res://assets/kenney_cursors/"

const CURSOR_APIS := [
	"set_custom_mouse_cursor",
	"set_default_cursor_shape",
	"cursor_set_custom_image",
]

const CHROME_PATHS := [
	"UI/RightDock",
	"UI/InventoryToggle",
	"UI/QuestLogToggle",
	"UI/QuestLogPanel",
	"UI/PartyToggle",
	"UI/PartyPanel",
	"UI/ClassHud",
	"UI/ClassDebug",
	"UI/HpHud",
	"UI/ErrorHud",
	"UI/DeathOverlay",
	"UI/Hotbar",
]

const CHROME_UNDER_TEST := [
	"UI/RightDock",
	"UI/InventoryToggle",
	"UI/QuestLogToggle",
	"UI/PartyToggle",
	"UI/Hotbar",
	"UI/ErrorHud",
]

const PLAYER_ID := 3
const REMOTE_PLAYER_ID := 7
const NODE_ID := 5
const HOSTILE_ID := 1000001
const FRIENDLY_ID := 1000002

const HOSTILE_GROUND := Vector2(10.0, 0.0)
const FRIENDLY_GROUND := Vector2(-10.0, 0.0)
const REMOTE_GROUND := Vector2(0.0, 10.0)
const NODE_GROUND := Vector2(0.0, -10.0)
const LOCAL_GROUND := Vector2(0.0, 0.0)
const EMPTY_GROUND := Vector2(20.0, 20.0)

const CAMERA_HEIGHT := 20.0
const OFFSET_FRACTION := 0.25
const AIM_HEIGHT := 0.8
const RECHECK_SECONDS := 0.25

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _camera: Camera3D = null
var _cursor: CursorHintScript = null
var _recheck: Timer = null
var _ui: CanvasLayer = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== cursor hint: the pointer says what the click will do ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "CursorHintClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_picker = _root.get_node("GroundPicker") as GroundPickerScript
	_camera = _root.get_node("CameraRig/Camera3D") as Camera3D
	_cursor = _root.get_node_or_null("CursorHint") as CursorHintScript
	_recheck = _root.get_node_or_null("CursorHint/Recheck") as Timer
	_ui = _root.get_node("UI") as CanvasLayer

	var rig := _root.get_node("CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	_test_the_owner_is_scene_authored()
	_test_the_table_covers_every_hint()
	_test_the_hotspots_are_the_decided_pixels()
	_test_one_script_owns_the_cursor()

	if _cursor == null or _recheck == null:
		_finish()
		return
	_recheck.stop()

	await _build_the_world()
	_test_the_headless_rects_say_where_to_aim()
	await _test_the_mapping_table()
	await _test_moving_off_a_hostile_restores_the_pointer()
	await _test_chrome_takes_the_hover()
	await _test_the_death_overlay_covers_the_sword()
	await _test_a_despawn_under_a_still_mouse_drops_the_sword()
	await _test_focus_and_mouse_exit_drop_the_sword()
	await _test_the_recheck_timer_covers_what_the_rules_miss()

	_finish()


func _finish() -> void:
	print(
		"CURSOR HINT RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_owner_is_scene_authored() -> void:
	_check(_cursor != null, "main.tscn authors a CursorHint node running cursor_hint.gd")
	if _cursor == null:
		return
	_check(
		_cursor.get_script().resource_path == OWNER_PATH,
		"whose script is %s, got %s" % [OWNER_PATH, _cursor.get_script().resource_path],
	)
	_check(_cursor.picker != null, "the scene binds its picker export")
	_check(_cursor.camera != null, "and its camera export")
	_check(_cursor.local_player != null, "and its local_player export")
	_check(_cursor.chrome_layer == _ui, "and its chrome_layer export to the UI layer")
	_check(_recheck != null, "the recheck timer is scene-authored")
	if _recheck == null:
		return
	_check(
		is_equal_approx(_recheck.wait_time, RECHECK_SECONDS),
		"the recheck timer waits %.2fs, got %.2f" % [RECHECK_SECONDS, _recheck.wait_time],
	)
	_check(
		not _recheck.is_stopped(),
		"and is already running, because the scene autostarts it",
	)
	_check(
		_recheck.timeout.is_connected(Callable(_cursor, "refresh")),
		"and the scene connects its timeout to refresh",
	)
	var session_source := FileAccess.get_file_as_string("res://scripts/session.gd")
	_check(
		not session_source.contains("cursor_hint"),
		"session never builds the cursor owner at runtime",
	)


func _test_the_table_covers_every_hint() -> void:
	_check(
		CursorHintScript.SHAPES.size() == CursorHintScript.Hint.size(),
		"SHAPES carries a row per Hint, got %d rows against %d hints"
		% [CursorHintScript.SHAPES.size(), CursorHintScript.Hint.size()],
	)
	for hint: int in CursorHintScript.Hint.values():
		var row: Dictionary = CursorHintScript.SHAPES.get(hint, {})
		var image := row.get("image") as Texture2D
		_check(image != null, "hint %d carries an image" % hint)
		if image == null:
			continue
		_check(
			image.resource_path.begins_with(ASSET_DIR),
			"hint %d draws from %s, got %s" % [hint, ASSET_DIR, image.resource_path],
		)


func _test_the_hotspots_are_the_decided_pixels() -> void:
	_check_hotspot(CursorHintScript.Hint.POINTER, Vector2(10, 8), "the arrow apex")
	_check_hotspot(CursorHintScript.Hint.ATTACK, Vector2(4, 4), "the blade tip")
	_check_hotspot(CursorHintScript.Hint.CHOP, Vector2(13, 3), "the top of the axe blade")


func _check_hotspot(hint: int, expected: Vector2, what: String) -> void:
	var row: Dictionary = CursorHintScript.SHAPES.get(hint, {})
	var hotspot: Vector2 = row.get("hotspot", Vector2.INF)
	_check(
		hotspot == expected,
		"hint %d hangs on %s at %s, got %s" % [hint, what, expected, hotspot],
	)


func _test_one_script_owns_the_cursor() -> void:
	var files := DirAccess.get_files_at(SCRIPTS_DIR)
	_check(
		files.has("cursor_hint.gd"),
		"the script scan can see %s, so a scan that found nothing cannot pass" % SCRIPTS_DIR,
	)
	var scanned := 0
	for file_name: String in files:
		if not file_name.ends_with(".gd"):
			continue
		var path := "%s/%s" % [SCRIPTS_DIR, file_name]
		var source := FileAccess.get_file_as_string(path)
		var sets_cursor := false
		for api: String in CURSOR_APIS:
			sets_cursor = sets_cursor or source.contains(api)
		_check(
			sets_cursor == (path == OWNER_PATH),
			"%s %s the cursor" % [file_name, "owns" if sets_cursor else "leaves"],
		)
		scanned += 1
	_check(scanned > 1, "and more than one script was scanned, got %d" % scanned)


func _build_the_world() -> void:
	await _feed(_welcome_with_npcs())
	await _feed(
		'{"node_spawn":{"id":%d,"kind":"tree","x":%f,"z":%f,"state":"full"}}'
		% [NODE_ID, NODE_GROUND.x, NODE_GROUND.y]
	)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_hostile() != null, "the world holds a hostile dummy")
	_check(_friendly() != null, "and a friendly dummy")
	_check(_session.avatar_for(REMOTE_PLAYER_ID) != null, "and a remote player avatar")
	_check(_session.node_for(NODE_ID) != null, "and a tree")


func _test_the_headless_rects_say_where_to_aim() -> void:
	var centre := _viewport_centre()
	var hotbar := _root.get_node("UI/Hotbar") as Control
	var toggle := _root.get_node("UI/InventoryToggle") as Control
	_check(
		hotbar.is_visible_in_tree() and hotbar.get_global_rect().has_point(centre),
		"the visible hotbar rect %s covers the viewport centre %s, so world hovers hide it"
		% [hotbar.get_global_rect(), centre],
	)
	_check(
		toggle.is_visible_in_tree() and toggle.get_global_rect().has_area(),
		"and the inventory toggle rect %s is authored with an area" % [toggle.get_global_rect()],
	)
	_check(
		toggle.get_global_rect().size.x >= 32.0 and toggle.get_global_rect().size.y >= 32.0,
		"and the formed inventory toggle is at least 32px so the chest icon reads, got %s"
		% [toggle.get_global_rect().size],
	)
	_check(
		not toggle.get_global_rect().has_point(Vector2(24, 24)),
		"while staying clear of the equipment pickup probe (24, 24) (got %s)"
		% [toggle.get_global_rect()],
	)

	_hide_the_chrome()
	_check(
		_chrome_names_at(centre).is_empty(),
		"with the chrome hidden nothing covers the centre, got %s" % [_chrome_names_at(centre)],
	)
	var beside := centre - _beside_offset()
	_check(
		_chrome_names_at(beside).is_empty(),
		"or the point beside it, got %s" % [_chrome_names_at(beside)],
	)


func _test_the_mapping_table() -> void:
	await _aim_at(HOSTILE_GROUND)
	_check_subject(_hostile(), "the hostile dummy")
	_check_hint(CursorHintScript.Hint.ATTACK, "a hostile dummy draws the sword")

	await _aim_at(FRIENDLY_GROUND)
	_check_subject(_friendly(), "the friendly dummy")
	_check_chrome(false, "the friendly dummy is world, not chrome")
	_check_hint(CursorHintScript.Hint.POINTER, "a friendly dummy keeps the pointer")

	await _aim_at(REMOTE_GROUND)
	_check_subject(_session.avatar_for(REMOTE_PLAYER_ID), "the remote avatar")
	_check_hint(CursorHintScript.Hint.ATTACK, "another player's avatar draws the sword")

	await _aim_at(LOCAL_GROUND)
	_check_subject(_root.get_node("Player") as Node3D, "the local avatar")
	_check_chrome(false, "your own avatar is world, not chrome")
	_check_hint(CursorHintScript.Hint.POINTER, "the local avatar is never an attack target")

	await _aim_at(NODE_GROUND)
	_check_subject(_session.node_for(NODE_ID), "the tree")
	_check_hint(CursorHintScript.Hint.CHOP, "a resource node draws the axe")

	await _aim_at(EMPTY_GROUND)
	var bare := _picker.pick(_viewport_centre())
	_check(
		bare["target"] == GroundPickerScript.Target.GROUND,
		"empty ground resolves to the ground, got target %d" % bare["target"],
	)
	_check_chrome(false, "and bare ground is world, not chrome")
	_check_hint(CursorHintScript.Hint.POINTER, "and draws the pointer")


func _test_moving_off_a_hostile_restores_the_pointer() -> void:
	await _aim_at(HOSTILE_GROUND)
	_check_hint(CursorHintScript.Hint.ATTACK, "the hostile is under the mouse again")
	await _hover(_viewport_centre() - _beside_offset())
	_check_hint(
		CursorHintScript.Hint.POINTER,
		"moving off the hostile onto bare ground restores the pointer",
	)
	_check_chrome(false, "and does so because the world is bare, not because of chrome")


func _test_chrome_takes_the_hover() -> void:
	for path: String in CHROME_UNDER_TEST:
		await _one_chrome_control(path)


func _one_chrome_control(path: String) -> void:
	var control := _root.get_node_or_null(path) as Control
	_check(control != null, "main.tscn authors %s" % path)
	if control == null:
		return

	var rect := control.get_global_rect()
	var at := _point_inside(rect)
	_check(rect.has_point(at), "%s covers %s of its rect %s" % [path, at, rect])

	await _place_the_hostile_under(at)
	await _hover(at)
	_check_subject_at(at, _hostile(), "the hostile hidden behind %s" % path)
	_check_hint(
		CursorHintScript.Hint.ATTACK,
		"with %s hidden the world behind it draws the sword at %s" % [path, at],
	)

	control.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	_check_hint(
		CursorHintScript.Hint.POINTER,
		"%s takes the hover back and restores the pointer with no mouse motion" % path,
	)
	_check_chrome(true, "%s is what took the hover" % path)

	control.visible = false
	await get_tree().process_frame
	await get_tree().process_frame
	_check_hint(
		CursorHintScript.Hint.ATTACK,
		"and hiding %s hands the hover back to the world, still with no motion" % path,
	)
	_check_chrome(false, "and %s stopped taking it" % path)


func _test_the_death_overlay_covers_the_sword() -> void:
	var overlay := _root.get_node("UI/DeathOverlay") as Control
	await _aim_at(HOSTILE_GROUND)
	_check_hint(CursorHintScript.Hint.ATTACK, "the hostile is under the mouse")
	_check(
		overlay.get_global_rect().has_point(_viewport_centre()),
		"the death overlay rect %s covers the whole viewport" % [overlay.get_global_rect()],
	)

	overlay.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	_check_hint(CursorHintScript.Hint.POINTER, "the death overlay covers the sword")
	_check_chrome(true, "and the overlay is what took the hover")

	overlay.visible = false
	await get_tree().process_frame
	await get_tree().process_frame
	_check_hint(
		CursorHintScript.Hint.ATTACK,
		"and dismissing it brings the sword back without any mouse motion",
	)


func _test_a_despawn_under_a_still_mouse_drops_the_sword() -> void:
	await _aim_at(HOSTILE_GROUND)
	_check_hint(CursorHintScript.Hint.ATTACK, "the hostile is under the mouse")

	await _feed(_welcome_without_npcs())
	await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_check_hint(
		CursorHintScript.Hint.POINTER,
		"a hostile despawning under a stationary mouse drops the sword",
	)

	await _build_the_world()


func _test_focus_and_mouse_exit_drop_the_sword() -> void:
	await _aim_at(HOSTILE_GROUND)
	_check_hint(CursorHintScript.Hint.ATTACK, "the hostile is under the mouse")

	_cursor.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_check_hint(CursorHintScript.Hint.POINTER, "losing window focus drops to the pointer at once")
	await get_tree().process_frame
	await get_tree().process_frame
	_check_hint(
		CursorHintScript.Hint.POINTER,
		"and stays there while the mouse position is unknown",
	)
	await _hover(_viewport_centre())
	_check_hint(
		CursorHintScript.Hint.ATTACK,
		"the first motion after regaining focus re-derives the sword",
	)

	_cursor.notification(Node.NOTIFICATION_WM_MOUSE_EXIT)
	_check_hint(CursorHintScript.Hint.POINTER, "the mouse leaving the window drops it too")
	await _hover(_viewport_centre())
	_check_hint(CursorHintScript.Hint.ATTACK, "and re-entering re-derives it")


func _test_the_recheck_timer_covers_what_the_rules_miss() -> void:
	await _feed(_welcome_without_npcs())
	_look_straight_down_at(HOSTILE_GROUND)
	await _hover(_viewport_centre())
	_check_hint(CursorHintScript.Hint.POINTER, "bare ground under the mouse draws the pointer")

	await _feed(_welcome_with_npcs())
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check_hint(
		CursorHintScript.Hint.POINTER,
		"a hostile spawning under a still mouse is past what the exact rules can see",
	)

	_recheck.start()
	_check(not _recheck.is_stopped(), "the recheck timer is armed again")
	_recheck.timeout.emit()
	_check_hint(CursorHintScript.Hint.ATTACK, "and its timeout re-derives the sword")


func _aim_at(ground: Vector2) -> void:
	_look_straight_down_at(ground)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _hover(_viewport_centre())


func _hover(at: Vector2) -> void:
	_hide_the_chrome()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	_camera.get_viewport().push_input(motion)
	await get_tree().process_frame
	await get_tree().process_frame


func _place_the_hostile_under(at: Vector2) -> void:
	_look_straight_down_at(HOSTILE_GROUND)
	var scale := _ground_pixels_to_world() * (CAMERA_HEIGHT - AIM_HEIGHT) / CAMERA_HEIGHT
	_check(scale > 0.0, "the camera projection is measurable, got %f per pixel" % scale)
	_look_straight_down_at(HOSTILE_GROUND - (at - _viewport_centre()) * scale)
	await get_tree().physics_frame
	await get_tree().physics_frame


func _ground_pixels_to_world() -> float:
	var centre = _picker.pick_ground(_viewport_centre())
	var stepped = _picker.pick_ground(_viewport_centre() + Vector2(0.0, 1.0))
	if centre == null or stepped == null:
		return 0.0
	return ((stepped as Vector2) - (centre as Vector2)).length()


func _point_inside(rect: Rect2) -> Vector2:
	var on_screen := rect.intersection(_camera.get_viewport().get_visible_rect())
	if on_screen.has_area():
		return on_screen.get_center()
	return rect.get_center()


func _hide_the_chrome() -> void:
	for path: String in CHROME_PATHS:
		var control := _root.get_node_or_null(path) as Control
		if control != null:
			control.visible = false


func _chrome_names_at(at: Vector2) -> Array[String]:
	var names: Array[String] = []
	_collect_chrome(_ui, at, names)
	return names


func _collect_chrome(parent: Node, at: Vector2, names: Array[String]) -> void:
	for child in parent.get_children():
		var control := child as Control
		if control != null:
			if not control.is_visible_in_tree():
				continue
			if control.get_global_rect().has_point(at):
				names.append(String(control.name))
		_collect_chrome(child, at, names)


func _hostile() -> NpcDummyScript:
	return _npc(HOSTILE_ID)


func _friendly() -> NpcDummyScript:
	return _npc(FRIENDLY_ID)


func _npc(id: int) -> NpcDummyScript:
	return _session.npcs.get_node_or_null("Npc%d" % id) as NpcDummyScript


func _check_subject(expected: Node3D, what: String) -> void:
	_check_subject_at(_viewport_centre(), expected, what)


func _check_subject_at(at: Vector2, expected: Node3D, what: String) -> void:
	var picked := _picker.pick(at)
	var resolved: Node3D = picked["player"]
	if resolved == null:
		resolved = picked["node"]
	_check(
		expected != null and resolved == expected,
		"%s sits under %s, got target %d and body %s" % [what, at, picked["target"], resolved],
	)


func _check_chrome(expected: bool, message: String) -> void:
	_check(
		_cursor.over_chrome() == expected,
		"%s (expected over_chrome %s, got %s)" % [message, expected, _cursor.over_chrome()],
	)


func _check_hint(expected: int, message: String) -> void:
	_check(
		_cursor.current_hint() == expected,
		"%s (expected hint %d, got %d)" % [message, expected, _cursor.current_hint()],
	)


func _look_straight_down_at(ground: Vector2) -> void:
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)),
		Vector3(ground.x, CAMERA_HEIGHT, ground.y),
	)


func _viewport_centre() -> Vector2:
	return _camera.get_viewport().get_visible_rect().size * 0.5


func _beside_offset() -> Vector2:
	return Vector2(_camera.get_viewport().get_visible_rect().size.y * OFFSET_FRACTION, 0.0)


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


static func _welcome_with_npcs() -> String:
	return (
		(
			'{"welcome":{"you":%d,"tick_ms":150,"tick":900,"players":['
			+ '{"id":%d,"x":%f,"z":%f},{"id":%d,"x":%f,"z":%f}],'
			+ '"items":[],"nodes":[],"npcs":['
			+ '{"id":%d,"kind":"dummy","faction":"hostile","x":%f,"z":%f,"hp":100,"max_hp":100},'
			+ '{"id":%d,"kind":"dummy","faction":"friendly","x":%f,"z":%f,"hp":100,"max_hp":100}'
			+ "]}}"
		)
		% [
			PLAYER_ID,
			PLAYER_ID,
			LOCAL_GROUND.x,
			LOCAL_GROUND.y,
			REMOTE_PLAYER_ID,
			REMOTE_GROUND.x,
			REMOTE_GROUND.y,
			HOSTILE_ID,
			HOSTILE_GROUND.x,
			HOSTILE_GROUND.y,
			FRIENDLY_ID,
			FRIENDLY_GROUND.x,
			FRIENDLY_GROUND.y,
		]
	)


static func _welcome_without_npcs() -> String:
	return (
		(
			'{"welcome":{"you":%d,"tick_ms":150,"tick":900,"players":['
			+ '{"id":%d,"x":%f,"z":%f}],"items":[],"nodes":[],"npcs":[]}}'
		)
		% [PLAYER_ID, PLAYER_ID, LOCAL_GROUND.x, LOCAL_GROUND.y]
	)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
