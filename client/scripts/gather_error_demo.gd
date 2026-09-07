extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")
const GroundItemScript := preload("res://scripts/ground_item.gd")

const TREE_KIND := "tree"
const LOGS_KIND := "logs"
const LUMBERJACK_CLASS := "lumberjack"
const KIT_KINDS: Array[String] = [
	"forester_cap",
	"forester_shirt",
	"forester_trousers",
	"lumberjack_axe",
]
const TOGGLE_KEY := KEY_I

const SCREENSHOT_WARMUP_FRAMES := 15
const JOIN_TIMEOUT_MSEC := 20000
const REFUSAL_TIMEOUT_MSEC := 8000
const CLEAR_TIMEOUT_MSEC := 12000
const PICKUP_TIMEOUT_MSEC := 20000
const EQUIP_TIMEOUT_MSEC := 15000
const CLASS_TIMEOUT_MSEC := 15000
const GATHER_TIMEOUT_MSEC := 20000
const SETTLE_MSEC := 700
const NODE_CLICK_HEIGHT := 1.8
const ITEM_CLICK_HEIGHT := 0.3

var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _inventory: InventoryPanelScript
var _equipment: EquipmentPanelScript
var _error_hud: Node
var _prefix: String
var _gather_intents := 0


func run(
	root: Node,
	session: SessionScript,
	inventory: InventoryPanelScript,
	equipment: EquipmentPanelScript,
	error_hud: Node,
	prefix: String,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_inventory = inventory
	_equipment = equipment
	_error_hud = error_hud
	_prefix = prefix

	_session.gather_requested.connect(func(_id: int) -> void: _gather_intents += 1)

	if not await _wait_until(
		func() -> bool:
			return _session.own_id() > 0 and _tree_node_id() > 0 and _kit_on_ground(),
		JOIN_TIMEOUT_MSEC,
	):
		return _fail(
			"no join, no seeded tree, or an incomplete ground kit after %dms" % JOIN_TIMEOUT_MSEC
		)
	print("DEMO joined %d" % _session.own_id())

	var node_id := _tree_node_id()
	var node := _session.node_for(node_id)
	print("DEMO seednode %d %s %f %f %s" % [node_id, node.kind, node.position.x, node.position.z, node.state])

	if not await _refuse_without_a_kit(node_id):
		return 1
	if not await _left_click_sends_no_gather(node_id):
		return 1
	if not await _wear_the_kit():
		return 1
	if not await _gather_with_the_kit(node_id):
		return 1

	print("DEMO done")
	return 0


func _refuse_without_a_kit(node_id: int) -> bool:
	var node := _session.node_for(node_id)
	var screen: Variant = _screen_position_of(node, NODE_CLICK_HEIGHT)
	if screen == null:
		return false

	_gather_intents = 0
	await _right_click_at(screen)
	print("DEMO gatherclick %d %f %f" % [node_id, screen.x, screen.y])
	if _gather_intents != 1:
		_fail("a right click on the tree sent %d gather intent(s), want 1" % _gather_intents)
		return false

	if not await _wait_until(
		func() -> bool:
			return not _hud_text().is_empty(),
		REFUSAL_TIMEOUT_MSEC,
	):
		_fail("no refusal text reached the screen within %dms" % REFUSAL_TIMEOUT_MSEC)
		return false
	print("DEMO errortext %s" % _hud_text())
	if not await _capture(1):
		return false

	var clear_start := Time.get_ticks_msec()
	if not await _wait_until(
		func() -> bool:
			return _hud_text().is_empty(),
		CLEAR_TIMEOUT_MSEC,
	):
		_fail("the refusal text never cleared within %dms" % CLEAR_TIMEOUT_MSEC)
		return false
	print("DEMO errorcleared %d" % (Time.get_ticks_msec() - clear_start))
	return await _capture(2)


func _left_click_sends_no_gather(node_id: int) -> bool:
	var node := _session.node_for(node_id)
	var screen: Variant = _screen_position_of(node, NODE_CLICK_HEIGHT)
	if screen == null:
		return false

	_gather_intents = 0
	await _left_click_at(screen)
	await _settle()
	print("DEMO leftclickgathers %d" % _gather_intents)
	if _gather_intents != 0:
		_fail("a left click on the tree sent %d gather intent(s), want 0" % _gather_intents)
		return false
	return true


func _wear_the_kit() -> bool:
	await _push_toggle_key()
	if not _equipment.visible:
		_fail("the equipment panel did not open after the toggle key")
		return false

	for kind: String in KIT_KINDS:
		var item_id := _ground_item_id(kind)
		if item_id == 0:
			_fail("no %s lies on the ground to pick up" % kind)
			return false
		var body := _session.item_for(item_id)
		var screen: Variant = _screen_position_of(body, ITEM_CLICK_HEIGHT)
		if screen == null:
			return false
		await _left_click_at(screen)
		print("DEMO pickupclick %s %d" % [kind, item_id])
		if not await _wait_until(
			func() -> bool:
				return _bag_slot_of(kind) >= 0,
			PICKUP_TIMEOUT_MSEC,
		):
			_fail("%s never reached the bag within %dms" % [kind, PICKUP_TIMEOUT_MSEC])
			return false
		print("DEMO bagged %s %d" % [kind, _bag_slot_of(kind)])

	for kind: String in KIT_KINDS:
		var slot := _bag_slot_of(kind)
		if slot < 0:
			_fail("%s left the bag before it could be equipped" % kind)
			return false
		await _right_click_bag_slot(slot)
		print("DEMO equipclick %s %d" % [kind, slot])
		if not await _wait_until(
			func() -> bool:
				return _bag_slot_of(kind) < 0,
			EQUIP_TIMEOUT_MSEC,
		):
			_fail("%s never left the bag after the equip click" % kind)
			return false

	if not await _wait_until(
		func() -> bool:
			return _session.active_class_id() == LUMBERJACK_CLASS,
		CLASS_TIMEOUT_MSEC,
	):
		_fail(
			"the active class never became %s, it is '%s'"
			% [LUMBERJACK_CLASS, _session.active_class_id()]
		)
		return false
	print("DEMO class %s" % _session.active_class_id())
	return true


func _gather_with_the_kit(node_id: int) -> bool:
	var node := _session.node_for(node_id)
	var screen: Variant = _screen_position_of(node, NODE_CLICK_HEIGHT)
	if screen == null:
		return false

	_gather_intents = 0
	await _right_click_at(screen)
	print("DEMO gatherclick %d %f %f" % [node_id, screen.x, screen.y])
	if _gather_intents != 1:
		_fail("a right click on the tree sent %d gather intent(s), want 1" % _gather_intents)
		return false

	if not await _wait_until(
		func() -> bool:
			return _bag_slot_of(LOGS_KIND) >= 0,
		GATHER_TIMEOUT_MSEC,
	):
		_fail("no %s reached the bag within %dms" % [LOGS_KIND, GATHER_TIMEOUT_MSEC])
		return false
	print("DEMO gathered %s %d" % [LOGS_KIND, _bag_slot_of(LOGS_KIND)])
	if not _hud_text().is_empty():
		_fail("a successful gather still put '%s' on the screen" % _hud_text())
		return false
	return await _capture(3)


func _hud_text() -> String:
	if _error_hud == null:
		return ""
	return _error_hud.text


func _tree_node_id() -> int:
	for id: int in _session.known_node_ids():
		var body := _session.node_for(id)
		if body != null and body.kind == TREE_KIND:
			return id
	return 0


func _ground_item_id(kind: String) -> int:
	for id: int in _session.known_item_ids():
		var body := _session.item_for(id)
		if body != null and body.kind == kind:
			return id
	return 0


func _kit_on_ground() -> bool:
	for kind: String in KIT_KINDS:
		if _ground_item_id(kind) == 0 and _bag_slot_of(kind) < 0:
			return false
	return true


func _bag_slot_of(kind: String) -> int:
	for slot in _inventory.slot_count():
		if _inventory.kind_in_slot(slot) == kind:
			return slot
	return -1


func _screen_position_of(body: Node3D, height: float) -> Variant:
	if body == null:
		_fail("nothing to click; the body left this client's registry")
		return null
	var camera := _root.get_viewport().get_camera_3d()
	if camera == null:
		_fail("the scene has no active camera to project from")
		return null
	var world := body.global_position + Vector3(0.0, height, 0.0)
	if camera.is_position_behind(world):
		_fail("%s is behind the camera; nothing on screen to click" % body.name)
		return null

	var screen := camera.unproject_position(world)
	var rect := _root.get_viewport().get_visible_rect()
	if not rect.has_point(screen):
		_fail("%s draws at (%f, %f), outside the viewport %s" % [body.name, screen.x, screen.y, rect])
		return null
	if _equipment.visible and _equipment.get_global_rect().has_point(screen):
		_fail(
			"%s draws at (%f, %f), under the right dock %s"
			% [body.name, screen.x, screen.y, _equipment.get_global_rect()]
		)
		return null
	print("DEMO screen %s %f %f %f %f" % [body.name, screen.x, screen.y, rect.size.x, rect.size.y])
	return screen


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
	print("DEMO errorhud %d %s" % [index, _hud_text()])
	print("DEMO shotclass %d %s" % [index, _session.active_class_id()])

	for id: int in _session.known_ids():
		var avatar: PlayerAvatarScript = _session.avatar_for(id)
		if avatar == null:
			continue
		print("DEMO pos %d %d %f %f" % [index, id, avatar.position.x, avatar.position.z])

	print("DEMO inv %d %d %d" % [index, _inventory.occupied_slot_count(), _inventory.slot_count()])
	for slot in _inventory.slot_count():
		var kind := _inventory.kind_in_slot(slot)
		if not kind.is_empty():
			print("DEMO invslot %d %d %s" % [index, slot, kind])

	for id: int in _session.known_node_ids():
		var body: ResourceNodeScript = _session.node_for(id)
		if body == null:
			continue
		print(
			"DEMO node %d %d %s %f %f %s"
			% [index, id, body.kind, body.position.x, body.position.z, body.state]
		)
	return true


func _wait_until(predicate: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _tree.process_frame
	return false


func _settle() -> void:
	var deadline := Time.get_ticks_msec() + SETTLE_MSEC
	while Time.get_ticks_msec() < deadline:
		await _tree.process_frame


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
	await _right_click_at(slot.get_global_rect().get_center())


func _left_click_at(position: Vector2) -> void:
	await _click_at(position, MOUSE_BUTTON_LEFT)


func _right_click_at(position: Vector2) -> void:
	await _click_at(position, MOUSE_BUTTON_RIGHT)


func _click_at(position: Vector2, button: int) -> void:
	var viewport := _root.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = position
		viewport.push_input(event)
	await _tree.process_frame


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
