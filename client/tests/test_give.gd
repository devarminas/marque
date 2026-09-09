extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const DialogPanelScript := preload("res://scripts/dialog_panel.gd")
const GivePanelScript := preload("res://scripts/give_panel.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const Assertions := preload("res://tests/assertions.gd")

const CAMERA_HEIGHT := 20.0
const CLICK_ITEM_ID := 5
const QUEST_NPC := 1000003
const OFFER_SLOT := 3
const SCRIPTS_DIR := "res://scripts"

const CHROME_PATHS := [
	"Margin",
	"Margin/Rows",
	"Margin/Rows/Heading",
	"Margin/Rows/Slots",
]

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _camera: Camera3D = null
var _dialog: DialogPanelScript = null
var _give: GivePanelScript = null
var _inventory: InventoryPanelScript = null

var _pickup_intents := PackedInt32Array()
var _give_intents: Array[Dictionary] = []
var _click_point := Vector2.INF


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== give: companion offer panel from dialog + active quest ==")
	DisplayServer.window_set_size(Vector2i(1280, 720))
	get_viewport().size = Vector2i(1280, 720)
	_test_the_panel_is_authored_before_anything_runs()

	_root = MainScene.instantiate() as Node3D
	_root.name = "GiveClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_picker = _root.get_node("GroundPicker") as GroundPickerScript
	_camera = _root.get_node("CameraRig/Camera3D") as Camera3D
	_dialog = _root.get_node("UI/DialogPanel") as DialogPanelScript
	_give = _root.get_node("UI/GivePanel") as GivePanelScript
	_inventory = _root.get_node("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript

	var rig := _root.get_node("CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	_session.pickup_requested.connect(func(id: int) -> void: _pickup_intents.append(id))
	_session.give_requested.connect(
		func(npc_id: int, slot: int) -> void:
			_give_intents.append({"npc": npc_id, "slot": slot})
	)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	_test_the_panel_hangs_off_the_ui_layer()
	_test_no_client_script_assigns_a_mouse_filter()
	await _test_open_and_close_rules()
	await _test_offer_sends_give_intent_without_local_delete()
	await _test_cancel_clears_without_closing_dialog()
	await _test_an_open_panel_swallows_a_click()
	await _test_a_closed_panel_lets_the_same_click_through()

	print(
		"GIVE RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_panel_is_authored_before_anything_runs() -> void:
	var unopened := MainScene.instantiate() as Node3D
	var panel := unopened.get_node_or_null("UI/GivePanel") as Control
	_check(panel != null, "main.tscn authors UI/GivePanel before any _ready runs")
	if panel == null:
		unopened.queue_free()
		return
	_check(panel.get_script() == GivePanelScript, "and it runs give_panel.gd")
	_check(not panel.visible, "and the scene file starts it closed")
	_check(
		panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and the scene file makes it opaque, got filter %d" % panel.mouse_filter,
	)
	var dialog := unopened.get_node_or_null("UI/DialogPanel") as Control
	_check(
		dialog != null and panel.get_parent() == dialog.get_parent(),
		"as a sibling of DialogPanel under UI/",
	)
	for path: String in CHROME_PATHS:
		var chrome := panel.get_node_or_null(path) as Control
		_check(chrome != null, "and authors %s inside it" % path)
		_check(
			chrome != null and chrome.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"which hands a missed click down to the panel (%s)" % path,
		)
	var cancel := panel.get_node_or_null("Margin/Rows/Cancel") as Button
	_check(cancel != null, "and authors a Cancel button")
	_check(
		cancel != null and cancel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"with STOP so Cancel takes the press",
	)
	unopened.queue_free()


func _test_the_panel_hangs_off_the_ui_layer() -> void:
	var layer := _give.get_parent()
	_check(layer != null and layer.name == "UI", "the give panel hangs off UI/")
	_check(layer is CanvasLayer, "which is a CanvasLayer")
	_check(
		_dialog != null and _give.get_parent() == _dialog.get_parent(),
		"beside DialogPanel, not nested inside it",
	)


func _test_no_client_script_assigns_a_mouse_filter() -> void:
	var assignment := RegEx.new()
	assignment.compile("mouse_filter\\s*=(?!=)")
	var source := FileAccess.get_file_as_string("%s/give_panel.gd" % SCRIPTS_DIR)
	_check(
		assignment.search(source) == null,
		"give_panel.gd never assigns mouse_filter; the scene owns click stop",
	)


func _test_open_and_close_rules() -> void:
	_check(not _give.visible, "the give panel starts closed")
	await _seed_quest_giver()
	_net.ingest_text_frame(
		'{"inventory":{"size":28,"slots":[{"slot":%d,"kind":"sticks"}]}}' % OFFER_SLOT
	)
	await get_tree().process_frame
	_check(not _give.visible, "inventory alone does not open give")

	_net.ingest_text_frame(
		'{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring Sticks",'
		+ '"objective":"Deliver 1 sticks","status":"active"}]}}'
	)
	await get_tree().process_frame
	_check(not _give.visible, "an active quest alone does not open give")

	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["Have you sticks?"],'
		% QUEST_NPC
		+ '"options":[{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	_check(_dialog.visible, "dialog opens for the quest_giver")
	_check(_give.visible, "dialog + quest_giver + active quest opens give")
	_check(_give.npc_id() == QUEST_NPC, "and caches the dialog npc")
	_check(
		_give.kind_in_slot(OFFER_SLOT) == "sticks",
		"and draws the bag cache as offer slots, got %s" % _give.kind_in_slot(OFFER_SLOT),
	)

	_net.ingest_text_frame(
		'{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring Sticks",'
		+ '"objective":"Deliver 1 sticks","status":"complete"}]}}'
	)
	await get_tree().process_frame
	_check(not _give.visible, "completing the quest closes give while dialog stays")
	_check(_dialog.visible, "dialog remains open after quest complete")

	_net.ingest_text_frame(
		'{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring Sticks",'
		+ '"objective":"Deliver 1 sticks","status":"active"}]}}'
	)
	await get_tree().process_frame
	_check(_give.visible, "reactivating the quest reopens give")

	_net.ingest_text_frame('{"dialog":{"npc":%d,"lines":[],"options":[]}}' % QUEST_NPC)
	await get_tree().process_frame
	_check(not _dialog.visible, "empty dialog closes talk")
	_check(not _give.visible, "and closes give with it")
	_check(_give.npc_id() == 0, "and clears the cached give npc")


func _test_offer_sends_give_intent_without_local_delete() -> void:
	_give_intents.clear()
	await _seed_quest_giver()
	_net.ingest_text_frame(
		'{"inventory":{"size":28,"slots":[{"slot":%d,"kind":"sticks"}]}}' % OFFER_SLOT
	)
	_net.ingest_text_frame(
		'{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring Sticks",'
		+ '"objective":"Deliver 1 sticks","status":"active"}]}}'
	)
	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["Have you sticks?"],'
		% QUEST_NPC
		+ '"options":[{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	_check(_give.visible, "give is open before an offer click")

	var slot := _give.slot_at(OFFER_SLOT)
	_check(slot != null and slot.is_occupied(), "offer slot %d is occupied" % OFFER_SLOT)
	if slot == null:
		return
	slot.pressed.emit()
	_check(
		_give_intents.size() == 1
		and _give_intents[0]["npc"] == QUEST_NPC
		and _give_intents[0]["slot"] == OFFER_SLOT,
		"activating an offer slot emits give_requested, got %s" % [_give_intents],
	)
	_check(
		_give.kind_in_slot(OFFER_SLOT) == "sticks",
		"and leave the offer slot alone until inventory restates",
	)
	_check(
		_inventory != null and _inventory.kind_in_slot(OFFER_SLOT) == "sticks",
		"and leave the bag panel alone until inventory restates",
	)

	_net.ingest_text_frame('{"dialog":{"npc":%d,"lines":[],"options":[]}}' % QUEST_NPC)
	await get_tree().process_frame


func _test_cancel_clears_without_closing_dialog() -> void:
	await _seed_quest_giver()
	_net.ingest_text_frame(
		'{"inventory":{"size":28,"slots":[{"slot":%d,"kind":"sticks"}]}}' % OFFER_SLOT
	)
	_net.ingest_text_frame(
		'{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring Sticks",'
		+ '"objective":"Deliver 1 sticks","status":"active"}]}}'
	)
	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["Have you sticks?"],'
		% QUEST_NPC
		+ '"options":[{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	_check(_give.visible and _dialog.visible, "both panels are open before Cancel")

	var cancel := _give.get_node("Margin/Rows/Cancel") as Button
	cancel.pressed.emit()
	_check(not _give.visible, "Cancel clears the give panel")
	_check(_give.npc_id() == 0, "and clears the cached give npc")
	_check(_dialog.visible, "without closing dialog")

	_net.ingest_text_frame(
		'{"inventory":{"size":28,"slots":[{"slot":%d,"kind":"sticks"}]}}' % OFFER_SLOT
	)
	await get_tree().process_frame
	_check(not _give.visible, "and stays closed across inventory restatement while dismissed")

	_net.ingest_text_frame('{"dialog":{"npc":%d,"lines":[],"options":[]}}' % QUEST_NPC)
	await get_tree().process_frame
	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["Have you sticks?"],'
		% QUEST_NPC
		+ '"options":[{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	_check(_give.visible, "a fresh dialog open after Cancel reopens give")

	_net.ingest_text_frame('{"dialog":{"npc":%d,"lines":[],"options":[]}}' % QUEST_NPC)
	await get_tree().process_frame


func _test_an_open_panel_swallows_a_click() -> void:
	_look_straight_down()
	await _seed_quest_giver()
	_net.ingest_text_frame(
		'{"inventory":{"size":28,"slots":[{"slot":%d,"kind":"sticks"}]}}' % OFFER_SLOT
	)
	_net.ingest_text_frame(
		'{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring Sticks",'
		+ '"objective":"Deliver 1 sticks","status":"active"}]}}'
	)
	_net.ingest_text_frame(
		'{"dialog":{"npc":%d,"lines":["Have you sticks?"],'
		% QUEST_NPC
		+ '"options":[{"id":"stop_talking"}]}}'
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	_click_point = _point_inside_the_panel()
	_check(
		_click_point != Vector2.INF,
		"the open give panel covers a point inside the viewport to click (rect %s)"
		% [_give.get_global_rect()],
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
		"but a click on the open give panel at %v sends no pickup, got %s"
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
		"with give closed the same click at %v picks item %d up, got %s"
		% [_click_point, CLICK_ITEM_ID, _pickup_intents],
	)


func _seed_quest_giver() -> void:
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


func _point_inside_the_panel() -> Vector2:
	var screen := _camera.get_viewport().get_visible_rect()
	var covered := _give.get_global_rect().intersection(screen)
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
