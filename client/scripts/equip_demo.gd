extends RefCounted

## M3 milestone: open equipment, equip the join-kit axe, unequip back to bag.
## Prints greppable `DEMO ` lines; `scripts/equip_demo.ps1` owns the assertions.

const SessionScript := preload("res://scripts/session.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const WornSlotScript := preload("res://scripts/worn_slot.gd")

const AXE_KIND := "axe"
const WEAPON_WORN := "weapon"
const TOGGLE_KEY := KEY_E

const SCREENSHOT_WARMUP_FRAMES := 15
const JOIN_TIMEOUT_MSEC := 20000
const RESTATE_TIMEOUT_MSEC := 10000

var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _inventory: InventoryPanelScript
var _equipment: EquipmentPanelScript
var _prefix: String


func run(
	root: Node,
	session: SessionScript,
	inventory: InventoryPanelScript,
	equipment: EquipmentPanelScript,
	prefix: String,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_inventory = inventory
	_equipment = equipment
	_prefix = prefix

	if not await _wait_for_join():
		return _fail("no join-kit axe in inventory after %dms" % JOIN_TIMEOUT_MSEC)
	print("DEMO joined %d" % _session.own_id())

	var axe_slot := _find_bag_axe_slot()
	if axe_slot < 0:
		return _fail("the join kit never placed an axe in the bag")

	await _push_toggle_key()
	if not _equipment.visible:
		return _fail("the equipment panel did not open after the toggle key")

	await _tree.process_frame
	await _tree.process_frame
	if not await _capture(1):
		return 1
	_print_equipment_layout(1)

	await _right_click_bag_slot(axe_slot)
	print("DEMO equipclick %d" % axe_slot)
	if not await _wait_for_equipped():
		return _fail("the weapon slot never showed the axe after equip")

	if not await _capture(2):
		return 1

	var weapon := _equipment.slot_at(WEAPON_WORN)
	if weapon == null or not weapon.is_occupied():
		return _fail("shot 2 has no occupied weapon slot to unequip")
	await _click_control(weapon)
	print("DEMO unequipclick %s" % WEAPON_WORN)
	if not await _wait_for_unequipped(axe_slot):
		return _fail("the axe never returned to bag slot %d after unequip" % axe_slot)

	if not await _capture(3):
		return 1

	print("DEMO done")
	return 0


func _wait_for_join() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.own_id() > 0 and _find_bag_axe_slot() >= 0:
			return true
		await _tree.process_frame
	return false


func _find_bag_axe_slot() -> int:
	for slot in _inventory.slot_count():
		if _inventory.kind_in_slot(slot) == AXE_KIND:
			return slot
	return -1


func _wait_for_equipped() -> bool:
	return await _wait_until(
		func() -> bool:
			return (
				_equipment.kind_in_slot(WEAPON_WORN) == AXE_KIND
				and _find_bag_axe_slot() < 0
			),
		RESTATE_TIMEOUT_MSEC,
	)


func _wait_for_unequipped(expected_slot: int) -> bool:
	return await _wait_until(
		func() -> bool:
			return (
				_equipment.kind_in_slot(WEAPON_WORN).is_empty()
				and _inventory.kind_in_slot(expected_slot) == AXE_KIND
			),
		RESTATE_TIMEOUT_MSEC,
	)


func _wait_until(predicate: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _tree.process_frame
	return false


func _push_toggle_key() -> void:
	var viewport := _root.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = TOGGLE_KEY
		event.pressed = pressed
		viewport.push_input(event)
	await _tree.process_frame


func _right_click_bag_slot(index: int) -> void:
	var slot := _inventory.slot_at(index) as InventorySlotScript
	if slot == null:
		_fail("bag slot %d has no widget to click" % index)
		return
	var viewport := _root.get_viewport()
	var center := slot.get_global_rect().get_center()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = pressed
		event.position = center
		viewport.push_input(event)
	await _tree.process_frame


func _click_control(control: Control) -> void:
	var viewport := _root.get_viewport()
	var center := control.get_global_rect().get_center()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = center
		viewport.push_input(event)
	await _tree.process_frame


func _print_equipment_layout(shot: int) -> void:
	var screen := _root.get_viewport().get_visible_rect()
	var rect := _equipment.get_global_rect()
	print(
		"DEMO equipopen %d %f %f %f %d"
		% [shot, rect.position.x, rect.end.x, screen.size.x, 1 if _equipment.visible else 0]
	)


func _capture(index: int) -> bool:
	for _frame in SCREENSHOT_WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	var path := "%s_%d.png" % [_prefix, index]
	var image := _root.get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("screenshot failed to save to %s: %d" % [path, error])
		return false
	print("DEMO shot %d %s" % [index, path])

	print(
		"DEMO inv %d %d %d"
		% [index, _inventory.occupied_slot_count(), _inventory.slot_count()]
	)
	for slot in _inventory.slot_count():
		var kind := _inventory.kind_in_slot(slot)
		if not kind.is_empty():
			print("DEMO invslot %d %d %s" % [index, slot, kind])

	var worn_kind := _equipment.kind_in_slot(WEAPON_WORN)
	if worn_kind.is_empty():
		print("DEMO worn %d %s" % [index, WEAPON_WORN])
	else:
		print("DEMO worn %d %s %s" % [index, WEAPON_WORN, worn_kind])
	return true


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
