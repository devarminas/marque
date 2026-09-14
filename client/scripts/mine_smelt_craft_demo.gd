extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const DemoAdminGive := preload("res://scripts/demo_admin_give.gd")

const ROCK_KIND := "rock"
const SMELTER_KIND := "smelter"
const ORE_KIND := "copper_ore"
const BAR_KIND := "copper_bar"
const STICKS_KIND := "sticks"
const SWORD_KIND := "sword"
const MINER_CLASS := "miner"

const MINER_KINDS: Array[String] = [
	"prospector_helm",
	"prospector_jacket",
	"prospector_legs",
	"prospector_boots",
	"pickaxe",
]
const ADMIN_GIVE_KINDS: Array[String] = [
	"prospector_helm",
	"prospector_jacket",
	"prospector_legs",
	"prospector_boots",
	"pickaxe",
	"sticks",
]

const SEED_ROCK_X := 2.0
const SEED_ROCK_Z := 3.0
const SEED_SMELTER_X := 0.0
const SEED_SMELTER_Z := 3.0
const COORD_EPS := 0.05
const NEAR_STATION := 0.45
const NODE_CLICK_HEIGHT := 1.8

const TOGGLE_KEY := KEY_I
const SCREENSHOT_WARMUP_FRAMES := 15
const JOIN_TIMEOUT_MSEC := 25000
const CLASS_TIMEOUT_MSEC := 15000
const GATHER_TIMEOUT_MSEC := 25000
const SMELT_TIMEOUT_MSEC := 15000
const CRAFT_TIMEOUT_MSEC := 15000
const WALK_TIMEOUT_MSEC := 20000
const HOLD_MSEC := 800


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

	if not await _wait_until(_world_ready, JOIN_TIMEOUT_MSEC):
		return _fail("join, rock, or smelter missing after %dms" % JOIN_TIMEOUT_MSEC)
	print("DEMO joined %d" % _session.own_id())

	var giver := DemoAdminGive.new()
	var give_err: String = await giver.grant(
		_session, _tree, ADMIN_GIVE_KINDS, JOIN_TIMEOUT_MSEC
	)
	if not give_err.is_empty():
		return _fail(give_err)

	var rock_id := _node_id_at(ROCK_KIND, SEED_ROCK_X, SEED_ROCK_Z)
	var smelter_id := _node_id_at(SMELTER_KIND, SEED_SMELTER_X, SEED_SMELTER_Z)
	if rock_id == 0 or smelter_id == 0:
		return _fail("seed rock or smelter missing from the registry")
	var rock := _session.node_for(rock_id)
	print(
		"DEMO seednode %d %s %f %f %s"
		% [rock_id, rock.kind, rock.position.x, rock.position.z, rock.state]
	)
	var smelter := _session.node_for(smelter_id)
	print(
		"DEMO seedstation %d %s %f %f"
		% [smelter_id, smelter.kind, smelter.position.x, smelter.position.z]
	)

	if not await _equip_kinds(MINER_KINDS, MINER_CLASS):
		return 1
	print("DEMO class %s" % _session.active_class_id())
	if not await _capture(1):
		return 1

	if not await _mine_rock(rock_id):
		return 1
	if not await _capture(2):
		return 1

	if not await _walk_near(SEED_SMELTER_X, SEED_SMELTER_Z):
		return 1
	if not await _smelt_ore(smelter_id):
		return 1
	if not await _capture(3):
		return 1

	if not await _craft_sword():
		return 1
	if not await _capture(4):
		return 1

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _world_ready() -> bool:
	if _session.own_id() <= 0:
		return false
	if _node_id_at(ROCK_KIND, SEED_ROCK_X, SEED_ROCK_Z) == 0:
		return false
	if _node_id_at(SMELTER_KIND, SEED_SMELTER_X, SEED_SMELTER_Z) == 0:
		return false
	return true


func _equip_kinds(kinds: Array[String], want_class: String) -> bool:
	await _ensure_equipment_open()
	for kind: String in kinds:
		var slot := _find_bag_kind(kind)
		if slot < 0:
			_fail("%s missing from the bag before equip" % kind)
			return false
		await _right_click_bag_slot(slot)
		print("DEMO equipclick %s %d" % [kind, slot])
	if not await _wait_until(
		func() -> bool:
			return _session.active_class_id() == want_class,
		CLASS_TIMEOUT_MSEC,
	):
		_fail(
			"active class never became %s, it is '%s'"
			% [want_class, _session.active_class_id()]
		)
		return false
	return true


func _mine_rock(rock_id: int) -> bool:
	var node := _session.node_for(rock_id)
	var screen: Variant = _screen_position_of(node)
	if screen == null:
		return false
	_click_at(screen, MOUSE_BUTTON_RIGHT)
	print("DEMO gatherclick %d %f %f" % [rock_id, screen.x, screen.y])
	if not await _wait_until(
		func() -> bool:
			return _find_bag_kind(ORE_KIND) >= 0,
		GATHER_TIMEOUT_MSEC,
	):
		_fail("%s never reached the bag after mining" % ORE_KIND)
		return false
	print("DEMO mined %s %d" % [ORE_KIND, _find_bag_kind(ORE_KIND)])
	return true


func _walk_near(x: float, z: float) -> bool:
	print("DEMO walkto %f %f" % [x, z])
	var deadline := Time.get_ticks_msec() + WALK_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var avatar := _session.avatar_for(_session.own_id())
		if avatar == null:
			await _tree.process_frame
			continue
		var here := Vector2(avatar.position.x, avatar.position.z)
		var there := Vector2(x, z)
		var dist := here.distance_to(there)
		if dist <= NEAR_STATION:
			_session.request_move(0.0, 0.0)
			# Let server pose catch the predicted avatar before station use.
			await _wait_msec(400)
			if _own_distance_to(x, z) <= NEAR_STATION:
				return true
		var wish := (there - here).normalized()
		_session.request_move(wish.x, wish.y)
		await _wait_msec(100)
	_session.request_move(0.0, 0.0)
	_fail("never reached station vicinity (%f,%f)" % [x, z])
	return false


func _smelt_ore(smelter_id: int) -> bool:
	var ore_slot := _find_bag_kind(ORE_KIND)
	if ore_slot < 0:
		_fail("no %s to smelt" % ORE_KIND)
		return false
	await _ensure_equipment_open()
	var widget := _inventory.slot_at(ore_slot) as InventorySlotScript
	if widget == null:
		_fail("bag slot %d has no widget for smelt" % ore_slot)
		return false
	await _click_control(widget)
	await _tree.process_frame
	if not _session.has_pending_use():
		_fail("ore slot click did not arm a pending use")
		return false
	var station := _session.node_for(smelter_id)
	var screen: Variant = _screen_position_of(station)
	if screen == null:
		return false
	_click_at(screen, MOUSE_BUTTON_LEFT)
	print("DEMO smeltclick %d %d" % [ore_slot, smelter_id])
	if not await _wait_until(
		func() -> bool:
			return _find_bag_kind(BAR_KIND) >= 0 and _find_bag_kind(ORE_KIND) < 0,
		SMELT_TIMEOUT_MSEC,
	):
		_fail("%s never replaced %s after smelt" % [BAR_KIND, ORE_KIND])
		return false
	print("DEMO smelted %s %d" % [BAR_KIND, _find_bag_kind(BAR_KIND)])
	return true


func _craft_sword() -> bool:
	var bar_slot := _find_bag_kind(BAR_KIND)
	if bar_slot < 0:
		_fail("no %s to craft" % BAR_KIND)
		return false
	if _find_bag_kind(STICKS_KIND) < 0:
		_fail("no %s for the sword recipe" % STICKS_KIND)
		return false
	await _ensure_equipment_open()
	var widget := _inventory.slot_at(bar_slot) as InventorySlotScript
	if widget == null:
		_fail("bag slot %d has no widget for craft" % bar_slot)
		return false
	await _click_control(widget)
	await _tree.process_frame
	await _click_control(widget)
	print("DEMO craftclick %d %d" % [bar_slot, bar_slot])
	if not await _wait_until(
		func() -> bool:
			return _find_bag_kind(SWORD_KIND) >= 0,
		CRAFT_TIMEOUT_MSEC,
	):
		_fail("%s never appeared after craft" % SWORD_KIND)
		return false
	print("DEMO crafted %s %d" % [SWORD_KIND, _find_bag_kind(SWORD_KIND)])
	return true


func _node_id_at(kind: String, x: float, z: float) -> int:
	var fallback := 0
	for id: int in _session.known_node_ids():
		var body := _session.node_for(id)
		if body == null or body.kind != kind:
			continue
		if fallback == 0:
			fallback = id
		if absf(body.position.x - x) <= COORD_EPS and absf(body.position.z - z) <= COORD_EPS:
			return id
	return fallback


func _own_distance_to(x: float, z: float) -> float:
	var avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	if avatar == null:
		return 999.0
	var dx := avatar.position.x - x
	var dz := avatar.position.z - z
	return sqrt(dx * dx + dz * dz)


func _find_bag_kind(kind: String) -> int:
	for slot in _inventory.slot_count():
		if _inventory.kind_in_slot(slot) == kind:
			return slot
	return -1


func _ensure_equipment_open() -> void:
	if _equipment.visible:
		return
	await _push_toggle_key()


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
	var worn_kind := _equipment.kind_in_slot("right hand")
	if worn_kind.is_empty():
		print("DEMO worn %d right hand" % index)
	else:
		print("DEMO worn %d right hand %s" % [index, worn_kind])
	for id: int in _session.known_node_ids():
		var body: ResourceNodeScript = _session.node_for(id)
		if body == null:
			continue
		print(
			"DEMO node %d %d %s %f %f %s"
			% [index, id, body.kind, body.position.x, body.position.z, body.state]
		)
	return true


func _screen_position_of(body: Node3D) -> Variant:
	var camera := _root.get_viewport().get_camera_3d()
	if camera == null:
		_fail("the scene has no active camera to project from")
		return null
	var world := body.global_position + Vector3(0.0, NODE_CLICK_HEIGHT, 0.0)
	if camera.is_position_behind(world):
		_fail("body %s is behind the camera" % body.name)
		return null
	var screen := camera.unproject_position(world)
	var rect := _root.get_viewport().get_visible_rect()
	if not rect.has_point(screen):
		_fail("body %s draws at (%f, %f), outside the viewport" % [body.name, screen.x, screen.y])
		return null
	if _inventory.visible and _inventory.get_global_rect().has_point(screen):
		_fail("body %s draws under the inventory panel" % body.name)
		return null
	if _equipment.visible and _equipment.get_global_rect().has_point(screen):
		_fail("body %s draws under the equipment panel" % body.name)
		return null
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
	_click_at(slot.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _tree.process_frame


func _click_control(control: Control) -> void:
	_click_at(control.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	await _tree.process_frame


func _click_at(position: Vector2, button: int) -> void:
	var viewport := _root.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = position
		viewport.push_input(event)


func _wait_until(predicate: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _tree.process_frame
	return false


func _wait_msec(msec: int) -> void:
	await _tree.create_timer(msec / 1000.0).timeout


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
