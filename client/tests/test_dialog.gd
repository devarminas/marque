extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const DialogPanelScript := preload("res://scripts/dialog_panel.gd")
const Assertions := preload("res://tests/assertions.gd")

const CAMERA_HEIGHT := 20.0
const CLICK_ITEM_ID := 5
const QUEST_NPC := 1000003
const SCRIPTS_DIR := "res://scripts"

const CHROME_PATHS := [
	"Margin",
	"Margin/Rows",
	"Margin/Rows/Lines",
	"Margin/Rows/Buttons",
]

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _camera: Camera3D = null
var _panel: DialogPanelScript = null

var _pickup_intents := PackedInt32Array()
var _talk_intents := PackedInt32Array()
var _option_intents: Array[Dictionary] = []
var _click_point := Vector2.INF


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== dialog: thin panel from server restatement ==")
	_test_the_panel_is_authored_before_anything_runs()

	_root = MainScene.instantiate() as Node3D
	_root.name = "DialogClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_picker = _root.get_node("GroundPicker") as GroundPickerScript
	_camera = _root.get_node("PlayerCharacter/CameraRig/Camera3D") as Camera3D
	_panel = _root.get_node("UI/DialogPanel") as DialogPanelScript

	var rig := _root.get_node("PlayerCharacter/CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	_session.pickup_requested.connect(func(id: int) -> void: _pickup_intents.append(id))
	_session.talk_requested.connect(func(id: int) -> void: _talk_intents.append(id))
	_session.dialog_option_requested.connect(
		func(npc_id: int, option_id: String) -> void:
			_option_intents.append({"npc": npc_id, "option": option_id})
	)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	_test_the_panel_hangs_off_the_ui_layer()
	_test_no_client_script_assigns_a_mouse_filter()
	await _test_restatement_opens_and_clears()
	await _test_buttons_send_dialog_option_intents()
	await _test_talk_intent_for_quest_giver()
	await _test_an_open_panel_swallows_a_click()
	await _test_a_closed_panel_lets_the_same_click_through()

	print(
		"DIALOG RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_panel_is_authored_before_anything_runs() -> void:
	var unopened := MainScene.instantiate() as Node3D
	var panel := unopened.get_node_or_null("UI/DialogPanel") as Control
	_check(panel != null, "main.tscn authors UI/DialogPanel before any _ready runs")
	if panel == null:
		unopened.queue_free()
		return
	_check(panel.get_script() == DialogPanelScript, "and it runs dialog_panel.gd")
	_check(not panel.visible, "and the scene file starts it closed")
	_check(
		panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and the scene file makes it opaque, got filter %d" % panel.mouse_filter,
	)
	for path: String in CHROME_PATHS:
		var chrome := panel.get_node_or_null(path) as Control
		_check(chrome != null, "and authors %s inside it" % path)
		_check(
			chrome != null and chrome.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"which hands a missed click down to the panel (%s)" % path,
		)
	unopened.queue_free()


func _test_the_panel_hangs_off_the_ui_layer() -> void:
	var layer := _panel.get_parent()
	_check(layer != null and layer.name == "UI", "the dialog hangs off UI/")
	_check(layer is CanvasLayer, "which is a CanvasLayer")


func _test_no_client_script_assigns_a_mouse_filter() -> void:
	var assignment := RegEx.new()
	assignment.compile("mouse_filter\\s*=(?!=)")
	var source := FileAccess.get_file_as_string("%s/dialog_panel.gd" % SCRIPTS_DIR)
	_check(
		assignment.search(source) == null,
		"dialog_panel.gd never assigns mouse_filter; the scene owns click stop",
	)


func _test_restatement_opens_and_clears() -> void:
	_check(not _panel.visible, "the dialog starts closed")
	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["Will you accept Bring Sticks?"],'
		% QUEST_NPC
		+ '"options":[{"id":"accept_quest"},{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	_check(_panel.visible, "a dialog restatement opens the panel")
	_check(_panel.npc_id() == QUEST_NPC, "and caches the npc id")
	var lines := _panel.get_node("Margin/Rows/Lines") as Label
	_check(
		lines != null and lines.text == "Will you accept Bring Sticks?",
		"and draws the server lines",
	)
	var accept := _panel.get_node("Margin/Rows/Buttons/AcceptQuest") as Button
	var stop := _panel.get_node("Margin/Rows/Buttons/StopTalking") as Button
	_check(accept != null and accept.visible, "Accept quest is shown for accept_quest")
	_check(stop != null and stop.visible, "Stop talking is shown for stop_talking")

	_net.ingest_text_frame('{"dialog":{"npc":%d,"lines":[],"options":[]}}' % QUEST_NPC)
	await get_tree().process_frame
	_check(not _panel.visible, "empty lines and options close the panel")
	_check(_panel.npc_id() == 0, "and clears the cached npc")


func _test_buttons_send_dialog_option_intents() -> void:
	_option_intents.clear()
	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["hi"],'
		% QUEST_NPC
		+ '"options":[{"id":"accept_quest"},{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	var accept := _panel.get_node("Margin/Rows/Buttons/AcceptQuest") as Button
	accept.pressed.emit()
	_check(
		_option_intents.size() == 1
		and _option_intents[0]["npc"] == QUEST_NPC
		and _option_intents[0]["option"] == "accept_quest",
		"Accept quest sends dialog_option accept_quest, got %s" % [_option_intents],
	)

	_option_intents.clear()
	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["hi"],'
		% QUEST_NPC
		+ '"options":[{"id":"accept_quest"},{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	var stop := _panel.get_node("Margin/Rows/Buttons/StopTalking") as Button
	stop.pressed.emit()
	_check(
		_option_intents.size() == 1
		and _option_intents[0]["option"] == "stop_talking",
		"Stop talking sends dialog_option stop_talking, got %s" % [_option_intents],
	)

	_net.ingest_text_frame('{"dialog":{"npc":%d,"lines":[],"options":[]}}' % QUEST_NPC)
	await get_tree().process_frame


func _test_talk_intent_for_quest_giver() -> void:
	_talk_intents.clear()
	_net.ingest_text_frame(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0,"hp":100,"max_hp":100}],'
		+ '"items":[],"nodes":[],'
		+ '"npcs":[{"id":%d,"kind":"quest_giver","faction":"neutral","x":2.0,"z":0.0,'
		% QUEST_NPC
		+ '"hp":100,"max_hp":100}]}}'
	)
	await get_tree().process_frame
	await get_tree().process_frame
	_session.request_talk(QUEST_NPC)
	_check(
		_talk_intents.size() == 1 and _talk_intents[0] == QUEST_NPC,
		"talk against a quest_giver emits talk_requested, got %s" % [_talk_intents],
	)
	_talk_intents.clear()
	_session.request_talk(1)
	_check(_talk_intents.is_empty(), "talk against an unknown npc is ignored")


func _test_an_open_panel_swallows_a_click() -> void:
	_look_straight_down()
	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["Will you accept Bring Sticks?"],'
		% QUEST_NPC
		+ '"options":[{"id":"accept_quest"},{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	_click_point = _point_inside_the_panel()
	_check(
		_click_point != Vector2.INF,
		"the open dialog covers a point inside the viewport to click (rect %s)"
		% [_panel.get_global_rect()],
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
		"and item %d stands on it so a click through would pick it up, got target %d"
		% [CLICK_ITEM_ID, resolved["target"]],
	)

	_pickup_intents.clear()
	await _push_left_click(_click_point)
	_check(
		_pickup_intents.is_empty(),
		"but a click on the open dialog at %v sends no pickup, got %s"
		% [_click_point, _pickup_intents],
	)


func _test_a_closed_panel_lets_the_same_click_through() -> void:
	if _click_point == Vector2.INF:
		return
	_net.ingest_text_frame('{"dialog":{"npc":%d,"lines":[],"options":[]}}' % QUEST_NPC)
	await get_tree().process_frame
	await get_tree().process_frame

	_pickup_intents.clear()
	await _push_left_click(_click_point)
	_check(
		_pickup_intents.size() == 1 and _pickup_intents[0] == CLICK_ITEM_ID,
		"with the dialog closed the same click at %v picks item %d up, got %s"
		% [_click_point, CLICK_ITEM_ID, _pickup_intents],
	)


func _point_inside_the_panel() -> Vector2:
	var screen := _camera.get_viewport().get_visible_rect()
	var covered := _panel.get_global_rect().intersection(screen)
	if not covered.has_area():
		return Vector2.INF
	return Vector2(
		covered.position.x + minf(12.0, covered.size.x * 0.2),
		covered.position.y + covered.size.y * 0.5,
	)


func _stand_an_item_at(ground: Vector2) -> void:
	_net.ingest_text_frame(
		'{"welcome":{"you":1,"tick_ms":150,"tick":900,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],"items":[]}}'
	)
	_net.ingest_text_frame(
		'{"item_spawn":{"id":%d,"kind":"sticks","x":%f,"z":%f}}'
		% [CLICK_ITEM_ID, ground.x, ground.y]
	)
	await get_tree().process_frame
	await get_tree().physics_frame


func _look_straight_down() -> void:
	_camera.global_position = Vector3(0.0, CAMERA_HEIGHT, 0.0)
	_camera.look_at(Vector3.ZERO, Vector3.FORWARD)


func _push_left_click(at: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	_camera.get_viewport().push_input(press)
	await get_tree().process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	_camera.get_viewport().push_input(release)
	await get_tree().process_frame


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition
