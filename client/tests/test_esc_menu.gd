extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const EscMenuScript := preload("res://scripts/esc_menu.gd")
const StubNet := preload("res://tests/stub_move_net.gd")
const Assertions := preload("res://tests/assertions.gd")

const WELCOME := '{"welcome":{"you":1,"tick_ms":150,"tick":100,"players":[{"id":1,"x":0.0,"z":0.0},{"id":2,"x":3.0,"z":0.0}]}}'
const SETTLE_FRAMES := 3

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _menu: EscMenuScript = null
var _stub: StubNet = null
var _exit_count := 0


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== esc menu: scene-authored resume / options / exit ==")
	_test_the_menu_is_authored_before_anything_runs()

	_root = MainScene.instantiate() as Node3D
	_root.name = "EscMenuClient"
	var net := _root.get_node("Session/Net")
	net.set_script(StubNet)
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_menu = _root.get_node("UI/EscMenu") as EscMenuScript
	_stub = _root.get_node("Session/Net") as StubNet
	_menu.exit_requested.connect(func() -> void: _exit_count += 1)
	_stub.ingest_text_frame(WELCOME)

	await get_tree().process_frame
	await get_tree().process_frame

	_test_the_menu_hangs_off_the_ui_layer()
	_test_session_never_builds_the_menu()
	await _test_escape_opens_and_resume_closes()
	await _test_escape_cascade_clears_selection_before_menu()
	await _test_options_stub_and_back()
	await _test_exit_emits_without_quitting_the_suite()
	await _test_open_menu_blocks_move_chords()

	print(
		"ESC MENU RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_menu_is_authored_before_anything_runs() -> void:
	var unopened := MainScene.instantiate() as Node3D
	var menu := unopened.get_node_or_null("UI/EscMenu") as Control
	_check(menu != null, "main.tscn authors UI/EscMenu before any _ready runs")
	if menu == null:
		unopened.queue_free()
		return
	_check(not menu.visible, "EscMenu starts hidden")
	_check(menu.get_node_or_null("Center/Column/Resume") is Button, "Resume is scene-authored")
	_check(menu.get_node_or_null("Center/Column/Options") is Button, "Options is scene-authored")
	_check(menu.get_node_or_null("Center/Column/Exit") is Button, "Exit is scene-authored")
	_check(
		menu.get_node_or_null("OptionsPanel/Center/Column/Back") is Button,
		"Options Back is scene-authored",
	)
	unopened.queue_free()


func _test_the_menu_hangs_off_the_ui_layer() -> void:
	_check(_menu != null, "the live client has UI/EscMenu")
	_check(_menu.get_parent() != null and _menu.get_parent().name == "UI", "EscMenu is under UI")
	_check(not _menu.visible, "EscMenu starts closed on the live client")
	_check(not _session.is_esc_menu_open(), "session reports the menu closed")


func _test_session_never_builds_the_menu() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/session.gd")
	_check(
		not source.contains("EscMenuScript.new("),
		"session never builds the esc menu at runtime",
	)
	_check(
		not source.contains("add_child(_esc_menu)"),
		"session never adds an esc menu child at runtime",
	)


func _test_escape_opens_and_resume_closes() -> void:
	_check(not _session.is_esc_menu_open(), "precondition: menu closed")
	await _press_escape()
	_check(_session.is_esc_menu_open(), "Escape with nothing to clear opens the menu")
	_check(_menu.visible, "and EscMenu is visible")
	_check(not _menu.is_options_open(), "with options still closed")

	_menu.resume_button.pressed.emit()
	await get_tree().process_frame
	_check(not _session.is_esc_menu_open(), "Resume closes the menu")
	_check(not _menu.visible, "and hides EscMenu")

	await _press_escape()
	_check(_session.is_esc_menu_open(), "Escape opens again")
	await _press_escape()
	_check(not _session.is_esc_menu_open(), "Escape on an open menu resumes")


func _test_escape_cascade_clears_selection_before_menu() -> void:
	_session.clear_selection()
	_check(_session.select_player(2), "select a remote so Escape has work")
	_check(_session.selected_player_id() == 2, "precondition: remote selected")
	await _press_escape()
	_check(_session.selected_player_id() == 0, "Escape clears selection before opening the menu")
	_check(not _session.is_esc_menu_open(), "and does not open the menu on that press")
	await _press_escape()
	_check(_session.is_esc_menu_open(), "the next Escape opens the menu")
	_session.clear_selection()
	_close_via_resume()


func _test_options_stub_and_back() -> void:
	_menu.open_menu()
	_check(_session.is_esc_menu_open(), "precondition: menu open")
	_menu.options_button.pressed.emit()
	await get_tree().process_frame
	_check(_menu.is_options_open(), "Options opens the keybinds panel")
	_check(
		_menu.options_panel.get_node_or_null("Center/Column/Keybinds") != null,
		"Options authors the Keybinds rows",
	)
	_check(
		_menu.keybinds_panel != null,
		"EscMenu wires keybinds_panel",
	)
	await _press_escape()
	_check(
		_session.is_esc_menu_open() and not _menu.is_options_open(),
		"Escape from options returns to the menu",
	)
	_menu.open_options()
	_check(_menu.is_options_open(), "Options opens again for Back")
	_menu.options_back_button.pressed.emit()
	await get_tree().process_frame
	_check(
		_session.is_esc_menu_open() and not _menu.is_options_open(),
		"Back closes Options and keeps the menu",
	)
	_close_via_resume()


func _test_exit_emits_without_quitting_the_suite() -> void:
	_exit_count = 0
	var bound := Callable(_session, "_on_esc_exit_requested")
	if _menu.exit_requested.is_connected(bound):
		_menu.exit_requested.disconnect(bound)
	_menu.open_menu()
	_menu.exit_button.pressed.emit()
	await get_tree().process_frame
	_check(_exit_count == 1, "Exit emits exit_requested once, got %d" % _exit_count)
	_check(is_instance_valid(_root), "the suite stays alive with Session quit disconnected")
	if not _menu.exit_requested.is_connected(bound):
		_menu.exit_requested.connect(bound)
	_close_via_resume()


func _test_open_menu_blocks_move_chords() -> void:
	_close_via_resume()
	_stub.move_chords.clear()
	_set_key(KEY_W, true)
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	_check(not _stub.move_chords.is_empty(), "holding W while closed produces move chords")
	_stub.move_chords.clear()
	await _press_escape()
	_check(_session.is_esc_menu_open(), "Escape opens the menu while W is held")
	var after_open := _stub.move_chords.size()
	_check(
		after_open >= 1 and _stub.move_chords[after_open - 1] == Vector2.ZERO,
		"opening the menu sends an idle chord so the walk stops",
	)
	var snapshot := _stub.move_chords.size()
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	_check(
		_stub.move_chords.size() == snapshot,
		"no further move chords while the menu has focus, got %d more"
		% (_stub.move_chords.size() - snapshot),
	)
	_set_key(KEY_W, false)
	_close_via_resume()


func _close_via_resume() -> void:
	if _menu != null and _menu.is_open():
		_menu.close_menu()


func _press_escape() -> void:
	var viewport := get_viewport()
	var cancel := InputEventKey.new()
	cancel.keycode = KEY_ESCAPE
	cancel.physical_keycode = KEY_ESCAPE
	cancel.pressed = true
	viewport.push_input(cancel)
	await get_tree().process_frame


func _set_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
