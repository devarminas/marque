extends Node3D


const Assertions := preload("res://tests/assertions.gd")
const Keybinds := preload("res://scripts/keybinds.gd")
const MainScene := preload("res://scenes/main.tscn")
const EscMenuScript := preload("res://scripts/esc_menu.gd")
const KeybindsPanelScript := preload("res://scripts/keybinds_panel.gd")
const StubNet := preload("res://tests/stub_move_net.gd")

const WELCOME := '{"welcome":{"you":1,"tick_ms":150,"tick":100,"players":[{"id":1,"x":0.0,"z":0.0}]}}'
const TEST_PATH := "user://input_map_arm219_test.cfg"

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _menu: EscMenuScript = null
var _panel: KeybindsPanelScript = null
var _prior_path := ""


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== keybinds: rebind inventory / quest log under user:// ==")
	_prior_path = Keybinds.path
	Keybinds.path = TEST_PATH
	_wipe_test_file()
	Keybinds.restore_defaults()

	_test_defaults_and_action_names()
	_test_rebind_persists_across_apply()
	_test_swap_within_managed_pair()
	_test_refuse_reserved_and_foreign()
	_test_corrupt_file_restores_defaults()
	_test_action_press_still_toggles_after_rebind()

	_root = MainScene.instantiate() as Node3D
	_root.name = "KeybindsClient"
	var net := _root.get_node("Session/Net")
	net.set_script(StubNet)
	_world.add_child(_root)
	_menu = _root.get_node("UI/EscMenu") as EscMenuScript
	_panel = _root.get_node("UI/EscMenu/OptionsPanel/Center/Column/Keybinds") as KeybindsPanelScript
	(_root.get_node("Session/Net") as StubNet).ingest_text_frame(WELCOME)
	await get_tree().process_frame
	await get_tree().process_frame

	await _test_options_ui_captures_and_swaps()

	_cleanup()
	print(
		"KEYBINDS RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_defaults_and_action_names() -> void:
	_check(InputMap.has_action("toggle_inventory"), "toggle_inventory exists")
	_check(InputMap.has_action("toggle_quest_log"), "toggle_quest_log exists")
	_check(Keybinds.physical_keycode("toggle_inventory") == KEY_I, "default inventory is I")
	_check(Keybinds.physical_keycode("toggle_quest_log") == KEY_J, "default quest log is J")


func _test_rebind_persists_across_apply() -> void:
	_wipe_test_file()
	Keybinds.restore_defaults()
	var reason := Keybinds.rebind("toggle_inventory", KEY_K)
	_check(reason == "", "rebind inventory to K succeeds, got '%s'" % reason)
	_check(Keybinds.physical_keycode("toggle_inventory") == KEY_K, "InputMap now uses K")
	_check(FileAccess.file_exists(TEST_PATH), "save wrote %s" % TEST_PATH)

	Keybinds.restore_defaults()
	_check(Keybinds.physical_keycode("toggle_inventory") == KEY_I, "defaults restored in memory")
	Keybinds.apply_saved()
	_check(
		Keybinds.physical_keycode("toggle_inventory") == KEY_K,
		"apply_saved reloads K from disk",
	)
	Keybinds.restore_defaults()
	_wipe_test_file()


func _test_swap_within_managed_pair() -> void:
	Keybinds.restore_defaults()
	_wipe_test_file()
	var reason := Keybinds.rebind("toggle_inventory", KEY_J)
	_check(reason == "", "rebinding inventory onto J swaps, got '%s'" % reason)
	_check(Keybinds.physical_keycode("toggle_inventory") == KEY_J, "inventory took J")
	_check(Keybinds.physical_keycode("toggle_quest_log") == KEY_I, "quest log received I")
	Keybinds.restore_defaults()
	_wipe_test_file()


func _test_refuse_reserved_and_foreign() -> void:
	Keybinds.restore_defaults()
	_wipe_test_file()
	var escape_reason := Keybinds.rebind("toggle_inventory", KEY_ESCAPE)
	_check(escape_reason != "", "Escape is refused")
	_check(Keybinds.physical_keycode("toggle_inventory") == KEY_I, "inventory stays I after Escape")

	var move_reason := Keybinds.rebind("toggle_inventory", KEY_W)
	_check(move_reason.contains("move_forward"), "W is refused as move_forward, got '%s'" % move_reason)
	_check(Keybinds.physical_keycode("toggle_inventory") == KEY_I, "inventory stays I after W")

	var hotbar_reason := Keybinds.rebind("toggle_quest_log", KEY_1)
	_check(hotbar_reason.contains("hotbar_1"), "1 is refused as hotbar_1, got '%s'" % hotbar_reason)
	Keybinds.restore_defaults()
	_wipe_test_file()


func _test_corrupt_file_restores_defaults() -> void:
	Keybinds.restore_defaults()
	_wipe_test_file()
	var file := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	_check(file != null, "can write a corrupt cfg")
	if file != null:
		file.store_string("not a config file {{{")
		file.close()
	Keybinds.apply_saved()
	_check(
		Keybinds.physical_keycode("toggle_inventory") == KEY_I,
		"corrupt cfg restores inventory to I",
	)
	_check(
		Keybinds.physical_keycode("toggle_quest_log") == KEY_J,
		"corrupt cfg restores quest log to J",
	)
	_wipe_test_file()


func _test_action_press_still_toggles_after_rebind() -> void:
	Keybinds.restore_defaults()
	_wipe_test_file()
	_check(Keybinds.rebind("toggle_inventory", KEY_O) == "", "rebind inventory to O")
	Input.action_press("toggle_inventory")
	_check(Input.is_action_pressed("toggle_inventory"), "action_press works by name after rebind")
	Input.action_release("toggle_inventory")
	var press := InputEventKey.new()
	press.physical_keycode = KEY_O
	press.pressed = true
	_check(
		InputMap.event_is_action(press, "toggle_inventory"),
		"physical O maps to toggle_inventory",
	)
	Keybinds.restore_defaults()
	_wipe_test_file()


func _test_options_ui_captures_and_swaps() -> void:
	_check(_panel != null, "Options authors Keybinds panel")
	if _panel == null:
		return
	_check(
		_menu.keybinds_panel == _panel,
		"EscMenu exports the Keybinds panel",
	)
	_menu.open_options()
	await get_tree().process_frame
	_check(_menu.is_options_open(), "Options is open")
	_check(not _panel.is_capturing(), "not capturing yet")
	_panel.inventory_button.pressed.emit()
	await get_tree().process_frame
	_check(_panel.is_capturing(), "Inventory bind starts capture")
	_push_key(KEY_K)
	await get_tree().process_frame
	_check(not _panel.is_capturing(), "capture ends after a key")
	_check(Keybinds.physical_keycode("toggle_inventory") == KEY_K, "UI rebound inventory to K")
	_panel.quest_log_button.pressed.emit()
	await get_tree().process_frame
	_push_key(KEY_K)
	await get_tree().process_frame
	_check(Keybinds.physical_keycode("toggle_quest_log") == KEY_K, "UI swap gives quest log K")
	_check(Keybinds.physical_keycode("toggle_inventory") == KEY_J, "and inventory keeps prior quest key J")
	_panel.inventory_button.pressed.emit()
	await get_tree().process_frame
	_check(_panel.is_capturing(), "capture again for Esc cancel")
	_check(_menu.cancel_keybind_capture(), "EscMenu cancels capture")
	_check(not _panel.is_capturing(), "capture cleared without closing Options")
	_check(_menu.is_options_open(), "Options stays open after cancel")
	_menu.close_menu()


func _push_key(physical: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = physical
	event.pressed = true
	_panel._input(event)


func _wipe_test_file() -> void:
	_remove_user_file(TEST_PATH)


func _cleanup() -> void:
	Keybinds.restore_defaults()
	_wipe_test_file()
	Keybinds.path = _prior_path
	_remove_user_file(Keybinds.DEFAULT_PATH)


func _remove_user_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
