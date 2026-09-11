extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const InventorySlotScene := preload("res://scenes/inventory_slot.tscn")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const WornSlotScript := preload("res://scripts/worn_slot.gd")
const Assertions := preload("res://tests/assertions.gd")

const TOGGLE_ACTION := "toggle_inventory"
const TOGGLE_KEY := KEY_I

const EDGE_INSET := 16.0

const CAMERA_HEIGHT := 20.0

const CLICK_ITEM_ID := 5

const LAYOUT_EPSILON := 0.5

const SCRIPTS_DIR := "res://scripts"

const CHROME_PATHS := [
	"Margin",
	"Margin/Rows",
	"Margin/Rows/WornCross",
]

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _camera: Camera3D = null
var _panel: EquipmentPanelScript = null
var _inventory: InventoryPanelScript = null

var _pickup_intents := PackedInt32Array()

var _click_point := Vector2.INF


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== equipment: a panel the player opens, no server ==")
	_test_the_panel_is_authored_before_anything_runs()

	_root = MainScene.instantiate() as Node3D
	_root.name = "EquipmentClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_picker = _root.get_node("GroundPicker") as GroundPickerScript
	_camera = _root.get_node("PlayerCharacter/CameraRig/Camera3D") as Camera3D
	_panel = _root.get_node("UI/RightDock") as EquipmentPanelScript
	_inventory = _root.get_node("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript

	var rig := _root.get_node("PlayerCharacter/CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	_session.pickup_requested.connect(func(id: int) -> void: _pickup_intents.append(id))

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	_test_the_panel_hangs_off_the_ui_layer()
	_test_no_client_script_assigns_a_mouse_filter()
	_test_the_toggle_flips_visibility()
	_test_the_keybind_is_authored()
	await _test_the_authored_key_opens_and_closes_it()
	await _test_the_worn_weapon_slot_is_drawn_empty()
	await _test_the_panel_is_left_anchored_where_it_is_drawn()
	await _test_an_open_panel_swallows_a_click()
	await _test_a_closed_panel_lets_the_same_click_through()
	await _test_toggling_never_re_arms_the_filter()

	print(
		"EQUIPMENT RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_panel_is_authored_before_anything_runs() -> void:
	var unopened := MainScene.instantiate() as Node3D
	var panel := unopened.get_node_or_null("UI/RightDock") as Control
	_check(panel != null, "main.tscn authors UI/RightDock, before any _ready runs")
	if panel == null:
		unopened.queue_free()
		return

	_check(
		panel.get_script() == EquipmentPanelScript,
		"and it runs equipment_panel.gd",
	)
	_check(
		not panel.visible,
		"and the scene file is what starts it closed, not a script",
	)
	_check(
		panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and the scene file is what makes it opaque, got filter %d" % panel.mouse_filter,
	)
	_check(
		panel.anchor_left == 1.0 and panel.anchor_right == 1.0,
		"and anchors it to the right edge, got left %f right %f"
		% [panel.anchor_left, panel.anchor_right],
	)

	var toggle := unopened.get_node_or_null("UI/InventoryToggle") as Button
	_check(toggle != null, "and authors UI/InventoryToggle beside the dock")
	_check(
		toggle != null and toggle.mouse_filter == Control.MOUSE_FILTER_STOP,
		"with STOP so the closed dock still offers a clickable I",
	)

	for path: String in CHROME_PATHS:
		var chrome := panel.get_node_or_null(path) as Control
		_check(chrome != null, "and authors %s inside it" % path)
		_check(
			chrome != null and chrome.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"which hands a missed click down to the panel rather than catching it (%s)" % path,
		)

	unopened.queue_free()


func _test_the_panel_hangs_off_the_ui_layer() -> void:
	var layer := _panel.get_parent()
	_check(layer != null and layer.name == "UI", "the dock hangs off UI/")
	_check(layer is CanvasLayer, "which is a CanvasLayer, so it draws over the world")
	_check(
		_inventory != null and _inventory.get_parent().get_parent().get_parent() == _panel,
		"and nests the inventory panel under the dock",
	)
	_check(
		_panel.anchor_left == 1.0 and _panel.anchor_right == 1.0,
		"anchored to the right edge",
	)


func _test_no_client_script_assigns_a_mouse_filter() -> void:
	var files := DirAccess.get_files_at(SCRIPTS_DIR)
	_check(
		files.has("equipment_panel.gd"),
		"the script scan can see %s, so a scan that found nothing cannot pass" % SCRIPTS_DIR,
	)

	var assignment := RegEx.new()
	assignment.compile("mouse_filter\\s*=(?!=)")
	var scanned := 0
	for file_name: String in files:
		if not file_name.ends_with(".gd"):
			continue
		var source := FileAccess.get_file_as_string("%s/%s" % [SCRIPTS_DIR, file_name])
		_check(
			assignment.search(source) == null,
			"%s never assigns mouse_filter; where a click stops is the scene's to say"
			% file_name,
		)
		scanned += 1
	_check(scanned > 1, "and more than one script was scanned, got %d" % scanned)


func _test_the_worn_weapon_slot_is_drawn_empty() -> void:
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	var slot := _panel.get_node_or_null(
		"Margin/Rows/WornCross/HandsRow/RightHandSlot"
	) as WornSlotScript
	_check(slot != null, "the dock draws an authored right-hand worn slot")
	if slot == null:
		return
	_check(
		slot.get_global_rect().has_area(),
		"which is laid out with an area, got %s" % [slot.get_global_rect()],
	)

	var reference := InventorySlotScene.instantiate() as InventorySlotScript
	_check(
		slot.display_color() == reference.empty_color,
		"and drawn the very shade inventory_slot.tscn authors for an empty slot, %s, got %s"
		% [reference.empty_color, slot.display_color()],
	)
	reference.queue_free()

	_check(slot.worn_name == "right hand", "and named for the slot it is")
	_panel.visible = false


func _test_the_toggle_flips_visibility() -> void:
	_check(not _panel.visible, "the panel starts closed")
	_panel.toggle()
	_check(_panel.visible, "one toggle opens it")
	_panel.toggle()
	_check(not _panel.visible, "and the next closes it again")


func _test_the_keybind_is_authored() -> void:
	_check(
		InputMap.has_action(TOGGLE_ACTION),
		'project.godot authors the "%s" action' % TOGGLE_ACTION,
	)
	if not InputMap.has_action(TOGGLE_ACTION):
		return

	var press := InputEventKey.new()
	press.physical_keycode = TOGGLE_KEY
	press.pressed = true
	_check(
		InputMap.event_is_action(press, TOGGLE_ACTION),
		"and binds it to the physical I key, so it stays put on a non-QWERTY layout",
	)


func _test_the_authored_key_opens_and_closes_it() -> void:
	_check(not _panel.visible, "the panel is closed before the key is pressed")

	await _push_toggle_key()
	_check(_panel.visible, "pressing the authored key opens the panel")

	await _push_toggle_key()
	_check(not _panel.visible, "and pressing it again closes it")


func _test_the_panel_is_left_anchored_where_it_is_drawn() -> void:
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	var screen := _camera.get_viewport().get_visible_rect()
	var rect := _panel.get_global_rect()
	print("EQUIPMENT panel rect %s in viewport %s" % [rect, screen.size])

	_check(rect.has_area(), "the open dock is laid out with an area, got %s" % [rect])
	_check(
		absf(rect.end.x - (screen.size.x - EDGE_INSET)) < LAYOUT_EPSILON,
		"its right edge sits %f px from the right edge, expected %f"
		% [screen.size.x - rect.end.x, EDGE_INSET],
	)
	_check(
		absf(rect.end.y - (screen.size.y - EDGE_INSET)) < LAYOUT_EPSILON,
		"and its bottom edge sits %f px from the bottom, expected %f"
		% [screen.size.y - rect.end.y, EDGE_INSET],
	)
	_panel.visible = false


func _test_an_open_panel_swallows_a_click() -> void:
	_look_straight_down()
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	_click_point = _point_inside_the_panel()
	_check(
		_click_point != Vector2.INF,
		"the open dock covers a point inside the viewport to click",
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
		"but a click on the open dock at %v sends no pickup, got %s"
		% [_click_point, _pickup_intents],
	)


func _test_a_closed_panel_lets_the_same_click_through() -> void:
	if _click_point == Vector2.INF:
		return
	_panel.visible = false
	await get_tree().process_frame
	await get_tree().process_frame

	_pickup_intents.clear()
	await _push_left_click(_click_point)
	_check(
		_pickup_intents.size() == 1 and _pickup_intents[0] == CLICK_ITEM_ID,
		"with the panel closed the very same click at %v picks item %d up, got %s"
		% [_click_point, CLICK_ITEM_ID, _pickup_intents],
	)


func _test_toggling_never_re_arms_the_filter() -> void:
	for _round in 3:
		_panel.toggle()
		await get_tree().process_frame
		_check(
			_panel.mouse_filter == Control.MOUSE_FILTER_STOP,
			"the filter is still STOP with the panel %s, got %d"
			% ["open" if _panel.visible else "closed", _panel.mouse_filter],
		)


func _point_inside_the_panel() -> Vector2:
	var screen := _camera.get_viewport().get_visible_rect()
	var covered := _panel.get_global_rect().intersection(screen)
	if not covered.has_area():
		return Vector2.INF
	return covered.get_center()


func _stand_an_item_at(ground: Vector2) -> void:
	_net.ingest_text_frame(
		'{"welcome":{"you":1,"tick_ms":150,"tick":900,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],"items":[]}}'
	)
	_net.ingest_text_frame(
		'{"item_spawn":{"id":%d,"kind":"acorn","x":%f,"z":%f}}'
		% [CLICK_ITEM_ID, ground.x, ground.y]
	)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame


func _push_toggle_key() -> void:
	var viewport := _camera.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = TOGGLE_KEY
		event.pressed = pressed
		viewport.push_input(event)
	await get_tree().process_frame


func _push_left_click(screen_position: Vector2) -> void:
	var viewport := _camera.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = screen_position
		viewport.push_input(event)
	await get_tree().process_frame


func _look_straight_down() -> void:
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)),
		Vector3(0.0, CAMERA_HEIGHT, 0.0),
	)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
