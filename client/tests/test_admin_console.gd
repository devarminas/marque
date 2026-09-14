extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const AdminConsoleScript := preload("res://scripts/admin_console.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const StubNet := preload("res://tests/stub_admin_net.gd")
const Assertions := preload("res://tests/assertions.gd")

const TOGGLE_ACTION := "toggle_admin_console"
const TOGGLE_KEY := KEY_QUOTELEFT
const CAMERA_HEIGHT := 20.0
const CLICK_ITEM_ID := 5
const WELCOME := '{"welcome":{"you":1,"tick_ms":150,"tick":100,"players":[{"id":1,"x":0.0,"z":0.0},{"id":2,"x":3.0,"z":0.0}]}}'
const SETTLE_FRAMES := 3
const SCRIPTS_DIR := "res://scripts"

const CHROME_PATHS := [
	"Margin",
	"Margin/Rows",
	"Margin/Rows/Heading",
	"Margin/Rows/Scroll",
	"Margin/Rows/Scroll/Scrollback",
	"Margin/Rows/InputRow",
	"Margin/Rows/InputRow/Prompt",
]

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _console: AdminConsoleScript = null
var _stub: StubNet = null
var _picker: GroundPickerScript = null
var _camera: Camera3D = null
var _admin_intents := PackedStringArray()
var _pickup_intents := PackedInt32Array()
var _click_point := Vector2.INF


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== admin console: backtick overlay sends intents only ==")
	_test_the_console_is_authored_before_anything_runs()

	_root = MainScene.instantiate() as Node3D
	_root.name = "AdminConsoleClient"
	var net := _root.get_node("Session/Net")
	net.set_script(StubNet)
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_console = _root.get_node("UI/AdminConsole") as AdminConsoleScript
	_stub = _root.get_node("Session/Net") as StubNet
	_picker = _root.get_node("GroundPicker") as GroundPickerScript
	_camera = _root.get_node("PlayerCharacter/CameraRig/Camera3D") as Camera3D
	var rig := _root.get_node("PlayerCharacter/CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)
	_session.admin_requested.connect(func(line: String) -> void: _admin_intents.append(line))
	_session.pickup_requested.connect(func(id: int) -> void: _pickup_intents.append(id))
	_stub.ingest_text_frame(WELCOME)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	_test_the_console_hangs_off_the_ui_layer()
	_test_session_never_builds_the_console()
	_test_no_client_script_assigns_a_mouse_filter()
	_test_the_keybind_is_authored()
	await _test_backtick_opens_and_closes_while_connected()
	await _test_backtick_ignored_while_disconnected()
	await _test_submit_sends_admin_intent_with_echo_and_reply()
	await _test_history_walks_with_up_and_down()
	await _test_open_console_blocks_move_chords()
	await _test_escape_closes_console_before_menu()
	await _test_an_open_console_swallows_a_click()
	await _test_a_closed_console_lets_the_same_click_through()

	print(
		"ADMIN CONSOLE RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_console_is_authored_before_anything_runs() -> void:
	var unopened := MainScene.instantiate() as Node3D
	var console := unopened.get_node_or_null("UI/AdminConsole") as Control
	_check(console != null, "main.tscn authors UI/AdminConsole before any _ready runs")
	if console == null:
		unopened.queue_free()
		return
	_check(console.get_script() == AdminConsoleScript, "and it runs admin_console.gd")
	_check(not console.visible, "and the scene file starts it closed")
	_check(
		console.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and the scene file makes it opaque, got filter %d" % console.mouse_filter,
	)
	_check(
		console.get_node_or_null("Margin/Rows/InputRow/Line") is LineEdit,
		"LineEdit input is scene-authored",
	)
	_check(
		console.get_node_or_null("Margin/Rows/Scroll/Scrollback") is RichTextLabel,
		"scrollback is scene-authored",
	)
	for path: String in CHROME_PATHS:
		var chrome := console.get_node_or_null(path) as Control
		_check(chrome != null, "and authors %s inside it" % path)
		_check(
			chrome != null and chrome.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"which hands a missed click down to the panel (%s)" % path,
		)
	unopened.queue_free()


func _test_the_console_hangs_off_the_ui_layer() -> void:
	_check(_console != null, "the live client has UI/AdminConsole")
	_check(
		_console.get_parent() != null and _console.get_parent().name == "UI",
		"AdminConsole is under UI",
	)
	_check(not _console.visible, "AdminConsole starts closed on the live client")
	_check(not _session.is_admin_console_open(), "session reports the console closed")


func _test_session_never_builds_the_console() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/session.gd")
	_check(
		not source.contains("AdminConsoleScript.new("),
		"session never builds the admin console at runtime",
	)
	_check(
		not source.contains("add_child(_admin_console)"),
		"session never adds an admin console child at runtime",
	)


func _test_no_client_script_assigns_a_mouse_filter() -> void:
	var assignment := RegEx.new()
	assignment.compile("mouse_filter\\s*=(?!=)")
	var source := FileAccess.get_file_as_string("%s/admin_console.gd" % SCRIPTS_DIR)
	_check(
		assignment.search(source) == null,
		"admin_console.gd never assigns mouse_filter; the scene owns click stop",
	)


func _test_the_keybind_is_authored() -> void:
	_check(InputMap.has_action(TOGGLE_ACTION), "project.godot authors %s" % TOGGLE_ACTION)
	var events := InputMap.action_get_events(TOGGLE_ACTION)
	var found := false
	for event: InputEvent in events:
		var key := event as InputEventKey
		if key != null and key.physical_keycode == TOGGLE_KEY:
			found = true
			break
	_check(found, "%s is bound to physical KEY_QUOTELEFT" % TOGGLE_ACTION)


func _test_backtick_opens_and_closes_while_connected() -> void:
	_stub.force_closed = false
	_check(not _session.is_admin_console_open(), "precondition: console closed")
	await _press_backtick()
	_check(_session.is_admin_console_open(), "backtick while connected opens the console")
	_check(_console.visible, "and AdminConsole is visible")
	await _press_backtick()
	_check(not _session.is_admin_console_open(), "backtick closes the console")
	_check(not _console.visible, "and hides AdminConsole")


func _test_backtick_ignored_while_disconnected() -> void:
	_close_console()
	_stub.force_closed = true
	await _press_backtick()
	_check(
		not _session.is_admin_console_open(),
		"backtick while disconnected does not open the console",
	)
	_stub.force_closed = false


func _test_submit_sends_admin_intent_with_echo_and_reply() -> void:
	_close_console()
	_stub.admin_lines.clear()
	_admin_intents.clear()
	await _press_backtick()
	_check(_session.is_admin_console_open(), "precondition: console open for submit")
	_console.line_edit.text = "/help"
	_console.line_edit.text_submitted.emit("/help")
	await get_tree().process_frame
	_check(_admin_intents == PackedStringArray(["/help"]), "submit emits admin_requested")
	_check(_stub.admin_lines == PackedStringArray(["/help"]), "and sends admin intent via net")
	_check(
		_console.scrollback_text().contains("> /help"),
		"scrollback shows local echo, got %s" % _console.scrollback_text(),
	)
	_stub.ingest_text_frame('{"admin_reply":{"text":"ok: noop ran"}}')
	await get_tree().process_frame
	_check(
		_console.scrollback_text().contains("ok: noop ran"),
		"scrollback shows server admin_reply, got %s" % _console.scrollback_text(),
	)
	var console_src := FileAccess.get_file_as_string("%s/admin_console.gd" % SCRIPTS_DIR)
	_check(
		not console_src.contains("inventory") and not console_src.contains("send_"),
		"console UI never mutates inventory or sends wire frames itself",
	)
	_close_console()


func _test_history_walks_with_up_and_down() -> void:
	_close_console()
	await _press_backtick()
	_console.line_edit.text_submitted.emit("/one")
	_console.line_edit.text_submitted.emit("/two")
	await get_tree().process_frame
	_console.line_edit.text = "draft"
	_console.line_edit.grab_focus()
	await get_tree().process_frame
	await _press_key(KEY_UP)
	_check(_console.line_edit.text == "/two", "up recalls the newest history entry")
	await _press_key(KEY_UP)
	_check(_console.line_edit.text == "/one", "second up walks older")
	await _press_key(KEY_DOWN)
	_check(_console.line_edit.text == "/two", "down walks newer")
	await _press_key(KEY_DOWN)
	_check(_console.line_edit.text == "draft", "down past the end restores the draft")
	_close_console()


func _test_open_console_blocks_move_chords() -> void:
	_close_console()
	_stub.move_chords.clear()
	_set_key(KEY_W, true)
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	_check(not _stub.move_chords.is_empty(), "holding W while closed produces move chords")
	_stub.move_chords.clear()
	await _press_backtick()
	_check(_session.is_admin_console_open(), "backtick opens the console while W is held")
	var after_open := _stub.move_chords.size()
	_check(
		after_open >= 1 and _stub.move_chords[after_open - 1] == Vector2.ZERO,
		"opening the console sends an idle chord so the walk stops",
	)
	var snapshot := _stub.move_chords.size()
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	_check(
		_stub.move_chords.size() == snapshot,
		"no further move chords while the console is open, got %d more"
		% (_stub.move_chords.size() - snapshot),
	)
	_set_key(KEY_W, false)
	_close_console()


func _test_escape_closes_console_before_menu() -> void:
	_close_console()
	await _press_backtick()
	_check(_session.is_admin_console_open(), "precondition: console open")
	await _press_escape()
	_check(not _session.is_admin_console_open(), "Escape closes the console")
	_check(not _session.is_esc_menu_open(), "and does not open the ESC menu on that press")
	await _press_escape()
	_check(_session.is_esc_menu_open(), "the next Escape opens the ESC menu")
	var menu := _root.get_node("UI/EscMenu")
	if menu.has_method("close_menu"):
		menu.close_menu()


func _test_an_open_console_swallows_a_click() -> void:
	_look_straight_down()
	_console.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	_click_point = _point_inside_the_console()
	_check(
		_click_point != Vector2.INF,
		"the open admin console covers a point inside the viewport to click (rect %s screen %s)"
		% [_console.get_global_rect(), _camera.get_viewport().get_visible_rect()],
	)
	if _click_point == Vector2.INF:
		return

	var under: Variant = _picker.pick_ground(_click_point)
	_check(under != null, "there is ground under %v to stand an item on" % _click_point)
	if under == null:
		_click_point = Vector2.INF
		return
	var here: Vector2 = under
	await _stand_an_item_at(here)
	var resolved := _picker.pick(_click_point)
	_check(
		resolved["target"] == GroundPickerScript.Target.ITEM,
		"and item %d stands on it, so a click that got through would pick it up, got target %d"
		% [CLICK_ITEM_ID, resolved["target"]],
	)

	_pickup_intents.clear()
	await _push_left_click(_click_point)
	_check(
		_pickup_intents.is_empty(),
		"but a click on the open admin console at %v sends no pickup, got %s"
		% [_click_point, _pickup_intents],
	)


func _test_a_closed_console_lets_the_same_click_through() -> void:
	if _click_point == Vector2.INF:
		return
	_console.visible = false
	await get_tree().process_frame
	await get_tree().process_frame

	_pickup_intents.clear()
	await _push_left_click(_click_point)
	_check(
		_pickup_intents.size() == 1 and _pickup_intents[0] == CLICK_ITEM_ID,
		"with the console closed the very same click at %v picks item %d up, got %s"
		% [_click_point, CLICK_ITEM_ID, _pickup_intents],
	)


func _look_straight_down() -> void:
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)),
		Vector3(0.0, CAMERA_HEIGHT, 0.0),
	)


func _point_inside_the_console() -> Vector2:
	var screen := _camera.get_viewport().get_visible_rect()
	var covered := _console.get_global_rect().intersection(screen)
	if not covered.has_area():
		return Vector2.INF
	return Vector2(
		covered.position.x + minf(12.0, covered.size.x * 0.2),
		covered.position.y + covered.size.y * 0.5,
	)


func _stand_an_item_at(ground: Vector2) -> void:
	_stub.ingest_text_frame(
		'{"welcome":{"you":1,"tick_ms":150,"tick":900,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],"items":[]}}'
	)
	_stub.ingest_text_frame(
		'{"item_spawn":{"id":%d,"kind":"acorn","x":%f,"z":%f}}'
		% [CLICK_ITEM_ID, ground.x, ground.y]
	)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame


func _push_left_click(screen_position: Vector2) -> void:
	var viewport := _camera.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = screen_position
		event.global_position = screen_position
		viewport.push_input(event)
	await get_tree().process_frame


func _close_console() -> void:
	if _console != null and _console.is_open():
		_console.close_console()


func _press_backtick() -> void:
	await _press_key(TOGGLE_KEY)


func _press_escape() -> void:
	await _press_key(KEY_ESCAPE)


func _press_key(key: Key) -> void:
	var viewport := get_viewport()
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	viewport.push_input(event)
	await get_tree().process_frame


func _set_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
