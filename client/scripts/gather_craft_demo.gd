extends RefCounted

## M4e milestone: equip the join-kit axe, race another client for the seeded
## tree, craft logs→sticks on a win. Prints greppable `DEMO ` lines;
## `scripts/gather_craft_demo.ps1` owns the assertions.

const SessionScript := preload("res://scripts/session.gd")
const TickClock := preload("res://scripts/tick_clock.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")

const AXE_KIND := "axe"
const WEAPON_WORN := "weapon"
const LOGS_KIND := "logs"
const STICKS_KIND := "sticks"
const TREE_KIND := "tree"
const TOGGLE_KEY := KEY_E

const SCREENSHOT_WARMUP_FRAMES := 15
const REQUIRED_PLAYERS := 2
const REQUIRED_NODES := 1
const JOIN_TIMEOUT_MSEC := 20000
const RESTATE_TIMEOUT_MSEC := 15000
const USEC_PER_MSEC := 1000

const CLICK_LEAD_TICKS := 40
const SHOT_BEFORE_LEAD_TICKS := 6
const SHOT_GATHERED_OFFSET_TICKS := 18
const SHOT_CRAFTED_OFFSET_TICKS := 40
const HOLD_UNTIL_OFFSET_TICKS := 52

const TICK_WAIT_BACKSTOP_MSEC := 90000
const SPIN_USEC := 20000
const NODE_CLICK_HEIGHT := 1.8
const GATHER_WAIT_MSEC := 8000

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

	var scenario_usec := await _wait_for_scenario()
	if scenario_usec < 0:
		return _fail(
			"fewer than %d player(s), %d tree node(s), or no bag axe after %dms"
			% [REQUIRED_PLAYERS, REQUIRED_NODES, JOIN_TIMEOUT_MSEC]
		)
	print("DEMO joined %d" % _session.own_id())

	var node_id := _tree_node_id()
	var node := _session.node_for(node_id)
	if node == null:
		return _fail("the seeded tree left the registry before the run started")
	print("DEMO seednode %d %s %f %f %s" % [node_id, node.kind, node.position.x, node.position.z, node.state])

	if not await _equip_axe():
		return 1

	var clock := _session.tick_clock()
	if not clock.is_anchored():
		return _fail("the tick clock is not anchored; there is no shared moment to click on")
	var tick_usec := clock.tick_ms() * USEC_PER_MSEC
	var ready_usec := ready_deadline_usec(scenario_usec, clock)
	print("DEMO sync %d %d" % [clock.estimated_tick_at(scenario_usec), clock.estimated_tick_at(ready_usec)])

	if not await _await_usec(ready_usec - SHOT_BEFORE_LEAD_TICKS * tick_usec):
		return _fail("frames stopped before the first capture")
	if not await _capture(1):
		return 1
	if _equipment.kind_in_slot(WEAPON_WORN) != AXE_KIND:
		return _fail("shot 1 has no worn axe")

	var screen_pos: Variant = _screen_position_of_node(node)
	if screen_pos == null:
		return 1
	var screen: Vector2 = screen_pos

	var click_usec := clock.next_guard_usec(Time.get_ticks_usec(), click_guard_usec(tick_usec))
	var click_tick := clock.estimated_tick_at(click_usec)
	if not await _await_usec(click_usec):
		return _fail("frames stopped before the gather click")
	_click_at(screen)
	print("DEMO gatherclick %d %d %f %f" % [clock.estimated_tick(), node_id, screen.x, screen.y])

	var saw_depleted := false
	var gather_deadline := Time.get_ticks_msec() + GATHER_WAIT_MSEC
	while Time.get_ticks_msec() < gather_deadline:
		if _node_is_depleted(node_id):
			saw_depleted = true
		if _find_bag_kind(LOGS_KIND) >= 0 or saw_depleted:
			break
		if clock.estimated_tick() >= click_tick + SHOT_GATHERED_OFFSET_TICKS and saw_depleted:
			break
		await _tree.process_frame

	if not await _await_tick(click_tick + SHOT_GATHERED_OFFSET_TICKS):
		return _fail("the clock stalled before the post-gather capture")
	if _find_bag_kind(LOGS_KIND) < 0 and not saw_depleted and not _node_is_depleted(node_id):
		return _fail("neither logs nor a depleted tree arrived after the gather")
	if not await _capture(2):
		return 1

	var won := _find_bag_kind(LOGS_KIND) >= 0
	print("DEMO outcome %d" % (1 if won else 0))
	if won:
		var logs_slot := _find_bag_kind(LOGS_KIND)
		if not await _craft_logs(logs_slot):
			return 1

	if not await _await_tick(click_tick + SHOT_CRAFTED_OFFSET_TICKS):
		return _fail("the clock stalled before the post-craft capture")
	if won and not await _wait_until(
		func() -> bool:
			return _find_bag_kind(STICKS_KIND) >= 0,
		RESTATE_TIMEOUT_MSEC,
	):
		return _fail("sticks never appeared after the craft")
	if not await _capture(3):
		return 1

	if not await _await_tick(click_tick + HOLD_UNTIL_OFFSET_TICKS):
		return _fail("the clock stalled during the hold")
	print("DEMO done")
	return 0


static func click_guard_usec(tick_usec: int) -> int:
	return tick_usec / 3


static func click_quantum_usec(tick_usec: int) -> int:
	return tick_usec * 8


static func ready_deadline_usec(scenario_usec: int, clock: TickClock) -> int:
	var tick_usec := clock.tick_ms() * USEC_PER_MSEC
	var quantum := click_quantum_usec(tick_usec)
	var quantized: int = ceili(float(scenario_usec) / float(quantum)) * quantum
	return quantized + CLICK_LEAD_TICKS * tick_usec


func _wait_for_scenario() -> int:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if (
			_session.known_ids().size() >= REQUIRED_PLAYERS
			and _tree_node_id() > 0
			and _find_bag_kind(AXE_KIND) >= 0
		):
			return Time.get_ticks_usec()
		await _tree.process_frame
	return -1


func _equip_axe() -> bool:
	var axe_slot := _find_bag_kind(AXE_KIND)
	if axe_slot < 0:
		_fail("the join kit never placed an axe in the bag")
		return false

	await _push_toggle_key()
	if not _equipment.visible:
		_fail("the equipment panel did not open after the toggle key")
		return false

	await _right_click_bag_slot(axe_slot)
	print("DEMO equipclick %d" % axe_slot)
	if not await _wait_until(
		func() -> bool:
			return _equipment.kind_in_slot(WEAPON_WORN) == AXE_KIND and _find_bag_kind(AXE_KIND) < 0,
		RESTATE_TIMEOUT_MSEC,
	):
		_fail("the weapon slot never showed the axe after equip")
		return false
	print("DEMO equipped %s" % AXE_KIND)
	return true


func _craft_logs(slot: int) -> bool:
	var widget := _inventory.slot_at(slot) as InventorySlotScript
	if widget == null:
		_fail("bag slot %d has no widget for the craft" % slot)
		return false
	await _click_control(widget)
	await _tree.process_frame
	await _click_control(widget)
	print("DEMO craftclick %d %d" % [slot, slot])
	return true


func _tree_node_id() -> int:
	for id: int in _session.known_node_ids():
		var body := _session.node_for(id)
		if body != null and body.kind == TREE_KIND:
			return id
	return 0


func _node_is_depleted(node_id: int) -> bool:
	var body := _session.node_for(node_id)
	return body != null and body.is_depleted()


func _find_bag_kind(kind: String) -> int:
	for slot in _inventory.slot_count():
		if _inventory.kind_in_slot(slot) == kind:
			return slot
	return -1


func _wait_until(predicate: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _tree.process_frame
	return false


func _await_usec(deadline_usec: int) -> bool:
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while Time.get_ticks_usec() < deadline_usec:
		if Time.get_ticks_msec() > backstop:
			return false
		if deadline_usec - Time.get_ticks_usec() > SPIN_USEC:
			await _tree.process_frame
	return true


func _await_tick(target: int) -> bool:
	var clock := _session.tick_clock()
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while clock.estimated_tick() < target:
		if Time.get_ticks_msec() > backstop:
			return false
		await _tree.process_frame
	return true


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

	var ids := _session.known_ids()
	print("DEMO players %d %d" % [index, ids.size()])
	for id: int in ids:
		var avatar: PlayerAvatarScript = _session.avatar_for(id)
		if avatar == null:
			continue
		print("DEMO pos %d %d %f %f" % [index, id, avatar.position.x, avatar.position.z])

	print("DEMO inv %d %d %d" % [index, _inventory.occupied_slot_count(), _inventory.slot_count()])
	for slot in _inventory.slot_count():
		var kind := _inventory.kind_in_slot(slot)
		if not kind.is_empty():
			print("DEMO invslot %d %d %s" % [index, slot, kind])

	var worn_kind := _equipment.kind_in_slot(WEAPON_WORN)
	if worn_kind.is_empty():
		print("DEMO worn %d %s" % [index, WEAPON_WORN])
	else:
		print("DEMO worn %d %s %s" % [index, WEAPON_WORN, worn_kind])

	for id: int in _session.known_node_ids():
		var body: ResourceNodeScript = _session.node_for(id)
		if body == null:
			continue
		print(
			"DEMO node %d %d %s %f %f %s"
			% [index, id, body.kind, body.position.x, body.position.z, body.state]
		)
	return true


func _screen_position_of_node(body: ResourceNodeScript) -> Variant:
	var camera := _root.get_viewport().get_camera_3d()
	if camera == null:
		_fail("the scene has no active camera to project from")
		return null
	var world := body.global_position + Vector3(0.0, NODE_CLICK_HEIGHT, 0.0)
	if camera.is_position_behind(world):
		_fail("node %s is behind the camera; nothing on screen to click" % body.name)
		return null

	var screen := camera.unproject_position(world)
	var rect := _root.get_viewport().get_visible_rect()
	if not rect.has_point(screen):
		_fail("node %s draws at (%f, %f), outside the viewport %s" % [body.name, screen.x, screen.y, rect])
		return null
	if _inventory.visible and _inventory.get_global_rect().has_point(screen):
		_fail(
			"node %s draws at (%f, %f), under the inventory panel %s"
			% [body.name, screen.x, screen.y, _inventory.get_global_rect()]
		)
		return null
	if _equipment.visible and _equipment.get_global_rect().has_point(screen):
		_fail(
			"node %s draws at (%f, %f), under the equipment panel %s"
			% [body.name, screen.x, screen.y, _equipment.get_global_rect()]
		)
		return null
	print("DEMO nodescreen %f %f %f %f" % [screen.x, screen.y, rect.size.x, rect.size.y])
	return screen


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
	_click_at(control.get_global_rect().get_center())
	await _tree.process_frame


func _click_at(position: Vector2) -> void:
	var viewport := _root.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		viewport.push_input(event)


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
