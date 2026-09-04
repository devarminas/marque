extends Node3D

## Equip, unequip, and worn restatement on the equipment panel. **M3c.**
##
## No server. Frames go through `net_client.gd`'s public [code]ingest_text_frame[/code]
## and clicks are real [InputEventMouseButton] events through a real viewport.

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const WornSlotScript := preload("res://scripts/worn_slot.gd")
const ItemKinds := preload("res://scripts/item_kinds.gd")
const Assertions := preload("res://tests/assertions.gd")

const WIRE_SIZE := 28
const AXE_SLOT := WIRE_SIZE - 1
const CAMERA_HEIGHT := 20.0

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _inventory: InventoryPanelScript = null
var _equipment: EquipmentPanelScript = null
var _camera: Camera3D = null

var _drop_intents := PackedInt32Array()
var _equip_intents := PackedInt32Array()
var _unequip_intents := PackedStringArray()


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== equipment wiring: equip, unequip, and worn restatement ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "EquipmentWiringClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_inventory = _root.get_node("UI/InventoryPanel") as InventoryPanelScript
	_equipment = _root.get_node("UI/EquipmentPanel") as EquipmentPanelScript
	_camera = _root.get_node("CameraRig/Camera3D") as Camera3D

	var rig := _root.get_node("CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	_session.drop_requested.connect(func(slot: int) -> void: _drop_intents.append(slot))
	_session.equip_requested.connect(func(slot: int) -> void: _equip_intents.append(slot))
	_session.unequip_requested.connect(func(worn: String) -> void: _unequip_intents.append(worn))

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	_test_axe_is_a_known_kind()
	await _test_equipment_restatement_draws_and_clears()
	await _test_left_click_still_drops()
	await _test_right_click_equips()
	await _test_drag_bag_to_weapon_equips()
	await _test_activate_worn_unequips()
	_test_intent_frames_match_the_protocol()

	print(
		"EQUIPMENT WIRING RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_axe_is_a_known_kind() -> void:
	_check(ItemKinds.is_known("axe"), 'item_kinds.gd knows "axe"')
	_check(not ItemKinds.is_known("sword"), "and unknown kinds stay unknown")


func _test_equipment_restatement_draws_and_clears() -> void:
	_equipment.visible = true
	await _feed('{"equipment":{"worn":["weapon"],"slots":[]}}')
	_check(_equipment.kind_in_slot("weapon") == "", "an empty equipment frame clears the weapon slot")

	await _feed('{"equipment":{"worn":["weapon"],"slots":[{"slot":"weapon","kind":"axe"}]}}')
	_check(
		_equipment.kind_in_slot("weapon") == "axe",
		'an equipment frame with an axe draws it in weapon, got "%s"' % _equipment.kind_in_slot("weapon"),
	)
	var slot := _equipment.slot_at("weapon")
	_check(slot != null, "which is the authored worn slot widget")
	if slot != null:
		_check(
			slot.display_color() == slot.known_color,
			"and draws axe green like a known inventory kind, got %s" % [slot.display_color()],
		)

	await _feed('{"equipment":{"worn":["weapon"],"slots":[]}}')
	_check(
		_equipment.kind_in_slot("weapon") == "",
		"a later empty equipment frame clears the slot again",
	)


func _test_left_click_still_drops() -> void:
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":%d,"kind":"axe"}]}}'
		% [WIRE_SIZE, AXE_SLOT]
	)
	_watch()
	await _left_click_slot(AXE_SLOT)
	_check(
		_drop_intents.size() == 1 and _drop_intents[0] == AXE_SLOT,
		"left-clicking the bag axe sends drop naming slot %d, got %s" % [AXE_SLOT, _drop_intents],
	)
	_check(_equip_intents.is_empty(), "and sends no equip")


func _test_right_click_equips() -> void:
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":%d,"kind":"axe"}]}}'
		% [WIRE_SIZE, AXE_SLOT]
	)
	_watch()
	await _right_click_slot(AXE_SLOT)
	_check(
		_equip_intents.size() == 1 and _equip_intents[0] == AXE_SLOT,
		"right-clicking the bag axe sends equip naming slot %d, got %s"
		% [AXE_SLOT, _equip_intents],
	)
	_check(_drop_intents.is_empty(), "and sends no drop")

	_watch()
	var stamped := NetClientScript.equip_frame(AXE_SLOT, _net.take_seq())
	_check(
		(stamped["equip"] as Dictionary).has("seq"),
		"equip carries seq when the client stamps it, got %s" % JSON.stringify(stamped),
	)


func _test_drag_bag_to_weapon_equips() -> void:
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":%d,"kind":"axe"}]}}'
		% [WIRE_SIZE, AXE_SLOT]
	)
	await _feed('{"equipment":{"worn":["weapon"],"slots":[]}}')
	_equipment.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	var bag := _inventory.slot_at(AXE_SLOT)
	var worn := _equipment.slot_at("weapon")
	_check(bag != null and worn != null, "both bag and weapon slots are drawn for drag")

	_watch()
	var data: Variant = bag._get_drag_data(Vector2.ZERO)
	_check(
		data != null and int(data["bag_slot"]) == AXE_SLOT,
		"an occupied bag slot offers drag data naming slot %d, got %s" % [AXE_SLOT, data],
	)
	_check(
		data != null and worn._can_drop_data(Vector2.ZERO, data),
		"and the weapon slot accepts that drag data",
	)
	if data != null:
		worn._drop_data(Vector2.ZERO, data)
	_check(
		_equip_intents.size() == 1 and _equip_intents[0] == AXE_SLOT,
		"dropping bag slot %d onto weapon sends equip, got %s" % [AXE_SLOT, _equip_intents],
	)


func _test_activate_worn_unequips() -> void:
	await _feed('{"equipment":{"worn":["weapon"],"slots":[{"slot":"weapon","kind":"axe"}]}}')
	_equipment.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	var worn := _equipment.slot_at("weapon")
	_check(worn != null and worn.is_occupied(), "the weapon slot holds an axe to unequip")

	_watch()
	await _left_click_control(worn)
	_check(
		_unequip_intents.size() == 1 and _unequip_intents[0] == "weapon",
		'activating worn weapon sends unequip naming "weapon", got %s' % _unequip_intents,
	)
	_check(
		_equipment.kind_in_slot("weapon") == "axe",
		"and the panel still shows the axe until the server restates it",
	)


func _test_intent_frames_match_the_protocol() -> void:
	_check(
		JSON.stringify(NetClientScript.equip_frame(3)) == '{"equip":{"slot":3}}',
		'equip is {"equip":{"slot":3}}, got %s' % JSON.stringify(NetClientScript.equip_frame(3)),
	)
	_check(
		JSON.stringify(NetClientScript.unequip_frame("weapon")) == '{"unequip":{"worn":"weapon"}}',
		'unequip is {"unequip":{"worn":"weapon"}}, got %s'
		% JSON.stringify(NetClientScript.unequip_frame("weapon")),
	)
	_check(
		(NetClientScript.equip_frame(1)["equip"] as Dictionary).has("slot")
		and (NetClientScript.unequip_frame("weapon")["unequip"] as Dictionary).has("worn"),
		"equip names a bag slot and unequip names a worn slot",
	)


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


func _watch() -> void:
	_drop_intents.clear()
	_equip_intents.clear()
	_unequip_intents.clear()


func _left_click_slot(index: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var slot := _inventory.slot_at(index)
	_check(slot != null, "slot %d exists to click" % index)
	if slot == null:
		return
	await _left_click_control(slot)


func _right_click_slot(index: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var slot := _inventory.slot_at(index)
	_check(slot != null, "slot %d exists to right-click" % index)
	if slot == null:
		return
	var viewport := _camera.get_viewport()
	var center := slot.get_global_rect().get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	press.position = center
	viewport.push_input(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_RIGHT
	release.pressed = false
	release.position = center
	viewport.push_input(release)
	await get_tree().process_frame


func _left_click_control(control: Control) -> void:
	var viewport := _camera.get_viewport()
	var center := control.get_global_rect().get_center()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = center
		viewport.push_input(event)
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
