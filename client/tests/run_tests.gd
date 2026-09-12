extends SceneTree


const TREE_FREE_SUITES: Array = [
	{"name": "tick clock", "script": preload("res://tests/test_tick_clock.gd")},
	{"name": "polyline walker", "script": preload("res://tests/test_polyline_walker.gd")},
	{"name": "steer integrate", "script": preload("res://tests/test_steer_integrate.gd")},
	{"name": "local mover", "script": preload("res://tests/test_local_mover.gd")},
	{"name": "nav mesh", "script": preload("res://tests/test_nav_mesh.gd")},
	{"name": "local mover nav", "script": preload("res://tests/test_local_mover_nav.gd")},
	{"name": "pose interp", "script": preload("res://tests/test_pose_interp.gd")},
	{"name": "item protocol", "script": preload("res://tests/test_item_protocol.gd")},
	{"name": "tick protocol", "script": preload("res://tests/test_tick_protocol.gd")},
	{"name": "tick edges", "script": preload("res://tests/test_tick_edges.gd")},
	{"name": "hp protocol", "script": preload("res://tests/test_hp_protocol.gd")},
	{"name": "class protocol", "script": preload("res://tests/test_class_protocol.gd")},
	{"name": "skills protocol", "script": preload("res://tests/test_skills_protocol.gd")},
	{"name": "dialog protocol", "script": preload("res://tests/test_dialog_protocol.gd")},
	{"name": "quest log protocol", "script": preload("res://tests/test_quest_log_protocol.gd")},
	{"name": "party protocol", "script": preload("res://tests/test_party_protocol.gd")},
	{"name": "give protocol", "script": preload("res://tests/test_give_protocol.gd")},
	{"name": "ability defs", "script": preload("res://tests/test_ability_defs.gd")},
	{"name": "casting protocol", "script": preload("res://tests/test_casting.gd")},
	{"name": "class defs", "script": preload("res://tests/test_class_defs.gd")},
	{"name": "grip defs", "script": preload("res://tests/test_grip_defs.gd")},
	{"name": "scene files", "script": preload("res://tests/test_scene_files.gd")},
	{"name": "dummy meter", "script": preload("res://tests/test_dummy_meter.gd")},
	{"name": "play map", "script": preload("res://tests/test_play_map.gd")},
]

const SCENE_SUITES: Array = [
	{"name": "world and camera", "scene": "res://tests/test_world.tscn"},
	{"name": "move chord", "scene": "res://tests/test_move_chord.tscn"},
	{"name": "player avatar", "scene": "res://tests/test_avatar.tscn"},
	{"name": "outfit", "scene": "res://tests/test_outfit.tscn"},
	{"name": "grip", "scene": "res://tests/test_grip.tscn"},
	{"name": "ground items", "scene": "res://tests/test_items.tscn"},
	{"name": "resource nodes", "scene": "res://tests/test_nodes.tscn"},
	{"name": "interaction", "scene": "res://tests/test_interaction.tscn"},
	{"name": "equipment", "scene": "res://tests/test_equipment.tscn"},
	{"name": "equipment wiring", "scene": "res://tests/test_equipment_wiring.tscn"},
	{"name": "hp", "scene": "res://tests/test_hp.tscn"},
	{"name": "target frame", "scene": "res://tests/test_target_frame.tscn"},
	{"name": "class", "scene": "res://tests/test_class.tscn"},
	{"name": "class debug", "scene": "res://tests/test_class_debug.tscn"},
	{"name": "error hud", "scene": "res://tests/test_error_hud.tscn"},
	{"name": "esc menu", "scene": "res://tests/test_esc_menu.tscn"},
	{"name": "keybinds", "scene": "res://tests/test_keybinds.tscn"},
	{"name": "dialog", "scene": "res://tests/test_dialog.tscn"},
	{"name": "quest log", "scene": "res://tests/test_quest_log.tscn"},
	{"name": "party", "scene": "res://tests/test_party.tscn"},
	{"name": "give", "scene": "res://tests/test_give.tscn"},
	{"name": "hotbar", "scene": "res://tests/test_hotbar.tscn"},
	{"name": "npcs", "scene": "res://tests/test_npcs.tscn"},
	{"name": "cast effect", "scene": "res://tests/test_cast_effect.tscn"},
	{"name": "cursor hint", "scene": "res://tests/test_cursor_hint.tscn"},
	{"name": "heartbeat", "scene": "res://tests/test_heartbeat.tscn"},
	{"name": "heartbeat edges", "scene": "res://tests/test_heartbeat_edges.tscn"},
	{"name": "interop", "scene": "res://tests/test_interop.tscn"},
	{"name": "wiring", "scene": "res://tests/test_wiring.tscn"},
	{"name": "world map", "scene": "res://tests/test_world_map.tscn"},
	{"name": "player character prop", "scene": "res://tests/test_player_character_prop.tscn"},
]

const Assertions := preload("res://tests/assertions.gd")

const STARTUP_GRACE_FRAMES := 10

const WATCHDOG_FRAMES := 1250

var _frames := 0
var _suite_frames := 0
var _suite_index := -1
var _expected_scene_path := ""
var _failures := PackedStringArray()
var _assertion_count := 0
var _tree_free_completed := 0
var _finished := false


func _initialize() -> void:
	var healthy := _run_tree_free_suites()
	if _tree_free_completed != TREE_FREE_SUITES.size():
		_fail(
			"only %d of %d tree-free suite(s) ran to completion"
			% [_tree_free_completed, TREE_FREE_SUITES.size()]
		)
		healthy = false
	if not healthy or SCENE_SUITES.is_empty():
		_report_and_quit()
		return
	process_frame.connect(_on_process_frame)
	_start_scene_suite(0)


func _finalize() -> void:
	if _finished:
		return
	push_error("tests did not run to completion: the main loop ended after %d frames" % _frames)
	quit(1)


func _run_tree_free_suites() -> bool:
	var healthy := true
	for suite in TREE_FREE_SUITES:
		var name: String = suite["name"]
		print("== %s (no scene tree) ==" % name)
		var script: GDScript = suite["script"]
		if not script.can_instantiate():
			_fail("suite '%s' did not compile" % name)
			return false
		var instance = script.new()
		if instance == null or not instance.has_method("run"):
			_fail("suite '%s' does not implement run(assertions)" % name)
			return false
		var assertions := Assertions.new()
		instance.run(assertions)
		if not assertions.completed:
			_fail("suite '%s' did not run to completion" % name)
			return false
		_tree_free_completed += 1
		if not _absorb(name, assertions.assertion_count, assertions.failures):
			healthy = false
	return healthy


func _start_scene_suite(index: int) -> void:
	_suite_index = index
	_suite_frames = 0
	_expected_scene_path = SCENE_SUITES[index]["scene"]
	print("== %s ==" % SCENE_SUITES[index]["name"])
	var error := change_scene_to_file(_expected_scene_path)
	if error != OK:
		_fail("could not load %s: %d" % [_expected_scene_path, error])
		_report_and_quit()


func _on_process_frame() -> void:
	if _finished:
		return
	_frames += 1
	_suite_frames += 1

	var suite: Dictionary = SCENE_SUITES[_suite_index]
	var scene := current_scene

	if _suite_frames == STARTUP_GRACE_FRAMES and not _check_suite_started(suite, scene):
		_report_and_quit()
		return

	if _frames >= WATCHDOG_FRAMES:
		_fail(
			"tests did not finish within %d frames (stuck in '%s')"
			% [WATCHDOG_FRAMES, suite["name"]]
		)
		_report_and_quit()
		return

	if scene == null or scene.scene_file_path != _expected_scene_path:
		return
	if not scene.has_method("is_finished") or not scene.is_finished():
		return

	if not _absorb(suite["name"], scene.get_assertion_count(), scene.get_failures()):
		_report_and_quit()
		return
	if _suite_index + 1 < SCENE_SUITES.size():
		_start_scene_suite(_suite_index + 1)
		return
	_report_and_quit()


func _check_suite_started(suite: Dictionary, scene: Node) -> bool:
	if scene == null or scene.scene_file_path != _expected_scene_path:
		_fail("%s did not become the current scene" % _expected_scene_path)
		return false
	if scene.get_script() == null:
		_fail("%s loaded but its script did not compile" % _expected_scene_path)
		return false
	for method in ["is_finished", "get_failures", "get_assertion_count"]:
		if not scene.has_method(method):
			_fail("%s does not implement the suite contract: %s()" % [_expected_scene_path, method])
			return false
	return true


func _absorb(name: String, assertion_count: int, failures: PackedStringArray) -> bool:
	print("  -- %d assertion(s), %d failure(s)" % [assertion_count, failures.size()])
	for failure in failures:
		_failures.append("%s: %s" % [name, failure])
	if assertion_count <= 0:
		_fail("suite '%s' ran zero assertions" % name)
		return false
	_assertion_count += assertion_count
	return true


func _fail(message: String) -> void:
	push_error(message)
	_failures.append(message)


func _report_and_quit() -> void:
	if _finished:
		return
	_finished = true
	if _failures.is_empty():
		print("PASS: %d assertion(s) held across %d suite(s)" % [
			_assertion_count, TREE_FREE_SUITES.size() + SCENE_SUITES.size()
		])
		quit(0)
		return
	printerr("FAIL: %d assertion(s) failed of %d" % [_failures.size(), _assertion_count])
	for failure in _failures:
		printerr("  - " + failure)
	quit(1)