extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const GroundItemScene := preload("res://scenes/ground_item.tscn")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const Assertions := preload("res://tests/assertions.gd")

const FEED_FIXTURE := "res://tests/fixtures/screenshot_world.ndjson"
const FEED_FIXTURE_FRAMES := 2
const FEED_FIXTURE_ITEMS := 2
const FEED_FIXTURE_PLAYERS := 1
const FEED_FIXTURE_SLOTS := 28
const FEED_FIXTURE_OCCUPIED := 3

const WIRE_SIZE := 28

const ODD_SIZE := 6

const ITEM_GROUND := Vector2(5.0, 8.0)

const NODE_GROUND := Vector2(-4.0, 6.0)

const REMOTE_GROUND := Vector2(6.0, -5.0)

const ITEM_ID := 3
const PLAYER_ID := 3
const NODE_ID := 3
const REMOTE_PLAYER_ID := 7

const CHROME_ITEM_ID := 11

const CAMERA_HEIGHT := 20.0

const OFFSET_FRACTION := 0.25

const EXACT_EPSILON := 0.01

const CHANNEL_EPSILON := 0.25

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _camera: Camera3D = null
var _panel: InventoryPanelScript = null
var _dock: EquipmentPanelScript = null
var _grid: GridContainer = null
var _items_container: Node3D = null

var _move_to_intents := PackedVector2Array()
var _pickup_intents := PackedInt32Array()
var _gather_intents := PackedInt32Array()
var _attack_intents := PackedInt32Array()
var _selection_events := PackedInt32Array()
var _drop_intents := PackedInt32Array()
var _use_intents: Array[Vector2i] = []
var _nodes_container: Node3D = null
var _remotes_container: Node3D = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	_root = MainScene.instantiate() as Node3D
	_root.name = "InteractionClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_picker = _root.get_node("GroundPicker") as GroundPickerScript
	_camera = _root.get_node("CameraRig/Camera3D") as Camera3D
	_panel = _root.get_node("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	_dock = _root.get_node("UI/RightDock") as EquipmentPanelScript
	_grid = _root.get_node("UI/RightDock/Margin/Rows/InventoryPanel/Margin/Rows/Slots") as GridContainer
	_items_container = _root.get_node("GroundItems") as Node3D
	_nodes_container = _root.get_node("ResourceNodes") as Node3D
	_remotes_container = _root.get_node("RemotePlayers") as Node3D

	var rig := _root.get_node("CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	_session.move_to_requested.connect(func(x: float, z: float) -> void:
		_move_to_intents.append(Vector2(x, z))
	)
	_session.pickup_requested.connect(func(id: int) -> void: _pickup_intents.append(id))
	_session.gather_requested.connect(func(id: int) -> void: _gather_intents.append(id))
	_session.attack_requested.connect(func(id: int) -> void: _attack_intents.append(id))
	_session.selection_changed.connect(func(id: int) -> void: _selection_events.append(id))
	_session.drop_requested.connect(func(slot: int) -> void: _drop_intents.append(slot))
	_session.use_requested.connect(
		func(slot: int, on: int) -> void: _use_intents.append(Vector2i(slot, on))
	)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	print("== interaction: clicks and the inventory panel, no server ==")
	_test_the_panel_is_authored()
	await _test_an_empty_inventory_draws_every_slot()
	await _test_one_occupied_slot()
	await _test_a_full_inventory()
	await _test_a_second_inventory_replaces_the_first_wholesale()
	await _test_both_ends_of_the_range()
	await _test_the_grid_size_comes_from_the_wire()
	await _test_an_unknown_kind_is_magenta()
	await _test_welcome_empties_the_panel()

	await _build_the_click_world()
	_test_the_picker_separates_an_item_from_the_ground()
	await _test_a_click_on_an_item_is_a_pickup_and_nothing_else()
	await _test_a_click_on_bare_ground_beside_an_item_sends_nothing()
	await _test_a_pickup_click_changes_nothing_locally()
	await _test_an_unregistered_body_is_never_picked_up()
	_test_the_intents_match_the_protocol_byte_for_byte()

	await _build_the_node_click_world()
	_test_the_picker_separates_a_node_from_the_ground()
	await _test_a_right_click_on_a_node_is_a_gather_and_nothing_else()
	await _test_a_left_click_on_a_node_sends_no_gather()
	await _test_a_click_on_bare_ground_beside_a_node_sends_nothing()
	await _test_a_click_on_an_item_still_picks_up_beside_a_node()

	await _build_the_player_click_world()
	_test_the_picker_separates_a_player_from_the_ground()
	await _test_a_click_on_a_remote_player_selects_and_does_not_attack()
	await _test_a_click_on_self_is_not_a_selection()
	await _test_a_ground_click_leaves_the_selection_alone()
	await _test_escape_clears_player_selection()
	await _test_a_right_click_on_a_remote_player_is_an_attack()

	await _test_clicking_an_occupied_slot_uses_it()
	await _test_cancel_clears_use_selection()
	await _test_clicking_an_empty_slot_uses_nothing()
	await _test_shift_clicking_an_occupied_slot_drops_it()
	await _test_clicking_the_panel_chrome_reaches_nothing()

	await _test_the_scripted_feed_still_builds_a_world()

	print(
		"INTERACTION RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_panel_is_authored() -> void:
	_check(_dock != null, "main.tscn authors UI/RightDock running equipment_panel.gd")
	_check(_panel != null, "with a nested inventory panel running inventory_panel.gd")
	_check(_grid != null, "with an authored grid for its slots")
	_check(
		_grid != null and _grid.get_child_count() == 0,
		"which starts empty, because how many slots exist is on the wire",
	)
	_check(
		_panel != null and _panel.slot_count() == 0,
		"and the panel draws no slots before any inventory frame",
	)
	_check(
		_dock != null and not _dock.visible,
		"and the dock starts closed so it cannot sit in front of the world"
		+ " swallowing clicks while the client is uninformed",
	)
	_check(
		_grid != null and _grid.columns > 0,
		"and the grid's column count is authored, not computed (%d)"
		% [0 if _grid == null else _grid.columns],
	)
	_check(
		_dock != null and _dock.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and the dock stops every click inside its rect, got filter %d"
		% (-1 if _dock == null else _dock.mouse_filter),
	)
	_check(
		_panel != null and _panel.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"while nested inventory chrome stays IGNORE, got filter %d"
		% (-1 if _panel == null else _panel.mouse_filter),
	)
	for chrome in [_panel.get_node("Margin"), _panel.get_node("Margin/Rows"), _grid]:
		var control := chrome as Control
		_check(
			control != null and control.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"and %s hands a missed click down rather than catching it"
			% [null if control == null else control.name],
		)


func _test_an_empty_inventory_draws_every_slot() -> void:
	await _feed('{"inventory":{"size":%d,"slots":[]}}' % WIRE_SIZE)
	_check(
		_panel.slot_count() == WIRE_SIZE,
		"an inventory of %d empty slots draws %d, got %d"
		% [WIRE_SIZE, WIRE_SIZE, _panel.slot_count()],
	)
	_check(
		_grid.get_child_count() == WIRE_SIZE,
		"and puts every one of them in the authored grid, got %d" % _grid.get_child_count(),
	)
	_check(
		_panel.occupied_slot_count() == 0,
		"and none of them is occupied, got %d" % _panel.occupied_slot_count(),
	)
	_check(_panel.kind_in_slot(0) == "", "and slot 0 holds nothing")
	var slot := _panel.slot_at(0)
	_check(slot != null and slot.disabled, "and an empty slot is a dead control")
	_check(
		slot != null and _is_color(slot.display_color(), slot.empty_color),
		"and draws the empty colour, got %s" % [null if slot == null else slot.display_color()],
	)


func _test_one_occupied_slot() -> void:
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":1,"kind":"acorn"}]}}' % WIRE_SIZE
	)
	_check(
		_panel.slot_count() == WIRE_SIZE,
		"one occupied slot still draws all %d, got %d" % [WIRE_SIZE, _panel.slot_count()],
	)
	_check(
		_panel.occupied_slot_count() == 1,
		"and exactly one is occupied, got %d" % _panel.occupied_slot_count(),
	)
	_check(_panel.kind_in_slot(1) == "acorn", 'and slot 1 holds "acorn"')
	_check(_panel.kind_in_slot(0) == "", "and slot 0, which the frame did not name, is empty")
	var held := _panel.slot_at(1)
	_check(held != null and not held.disabled, "and an occupied slot can be clicked")
	_check(
		held != null and held.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and is the one part of the panel that does take the click",
	)
	_check(
		held != null and _is_color(held.display_color(), held.known_color),
		"and draws green, which is Pickup, got %s"
		% [null if held == null else held.display_color()],
	)


func _test_a_full_inventory() -> void:
	await _feed(_inventory_frame(WIRE_SIZE, WIRE_SIZE))
	_check(
		_panel.occupied_slot_count() == WIRE_SIZE,
		"a full inventory occupies all %d slots, got %d"
		% [WIRE_SIZE, _panel.occupied_slot_count()],
	)
	_check(
		_panel.slot_count() == WIRE_SIZE,
		"and draws no more than %d, got %d" % [WIRE_SIZE, _panel.slot_count()],
	)


func _test_a_second_inventory_replaces_the_first_wholesale() -> void:
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":5,"kind":"acorn"}]}}' % WIRE_SIZE
	)
	_check(
		_panel.occupied_slot_count() == 1,
		"a second inventory replaces the first wholesale, got %d occupied"
		% _panel.occupied_slot_count(),
	)
	_check(_panel.kind_in_slot(5) == "acorn", "and slot 5 is what it named")
	_check(
		_panel.kind_in_slot(0) == "" and _panel.kind_in_slot(27) == "",
		"and every slot the previous frame filled is empty again",
	)


func _test_both_ends_of_the_range() -> void:
	var last := WIRE_SIZE - 1
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":0,"kind":"acorn"},{"slot":%d,"kind":"acorn"}]}}'
		% [WIRE_SIZE, last]
	)
	_check(_panel.kind_in_slot(0) == "acorn", "the first slot, 0, is drawn occupied")
	_check(_panel.kind_in_slot(last) == "acorn", "and so is the last, %d" % last)
	_check(
		_panel.occupied_slot_count() == 2,
		"and nothing between them, got %d occupied" % _panel.occupied_slot_count(),
	)
	_check(_panel.slot_at(WIRE_SIZE) == null, "and there is no slot %d to draw" % WIRE_SIZE)
	_check(_panel.slot_at(-1) == null, "and no slot -1")


func _test_the_grid_size_comes_from_the_wire() -> void:
	await _feed(_inventory_frame(ODD_SIZE, 1))
	_check(
		_panel.slot_count() == ODD_SIZE,
		"an inventory of %d draws %d slots, not %d, got %d"
		% [ODD_SIZE, ODD_SIZE, WIRE_SIZE, _panel.slot_count()],
	)
	_check(
		_grid.get_child_count() == ODD_SIZE,
		"and the grid holds exactly that many widgets, got %d" % _grid.get_child_count(),
	)
	await _feed('{"inventory":{"size":0,"slots":[]}}')
	_check(_panel.slot_count() == 0, "an inventory of no slots draws none")
	_check(_grid.get_child_count() == 0, "and clears the grid rather than drawing empty chrome")


func _test_an_unknown_kind_is_magenta() -> void:
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":2,"kind":"acorn"},'
		% WIRE_SIZE
		+ '{"slot":4,"kind":"bewilderment"}]}}'
	)
	var stranger := _panel.slot_at(4)
	_check(stranger != null, "a slot holding an unknown kind is still drawn")
	if stranger == null:
		return
	_check(stranger.kind == "bewilderment", "and holds the server's name for it verbatim")
	_check(
		_is_color(stranger.display_color(), stranger.unknown_color),
		"and draws magenta, which is missing-asset, got %s" % [stranger.display_color()],
	)
	var known := _panel.slot_at(2)
	_check(
		known != null and not _is_color(known.display_color(), stranger.display_color()),
		"and is nothing like the colour a known kind draws",
	)
	_check(not stranger.disabled, "and is still droppable, because the server knows what it is")


func _test_welcome_empties_the_panel() -> void:
	await _feed(_welcome_frame())
	_check(
		_panel.slot_count() == 0,
		"welcome empties the panel rather than leaving a stale one up, got %d slots"
		% _panel.slot_count(),
	)
	_check(_grid.get_child_count() == 0, "and empties the authored grid with it")
	_check(
		_panel.slot_count() == 0,
		"so bag size no longer owns dock visibility",
	)


func _build_the_click_world() -> void:
	_dock.visible = false
	var toggle := _root.get_node_or_null("UI/InventoryToggle") as CanvasItem
	if toggle != null:
		toggle.visible = false
	await _feed(_welcome_frame())
	await _feed(
		'{"item_spawn":{"id":%d,"kind":"acorn","x":%f,"z":%f}}'
		% [ITEM_ID, ITEM_GROUND.x, ITEM_GROUND.y]
	)
	_check(
		_session.item_for(ITEM_ID) != null,
		"the world holds item %d for the click tests" % ITEM_ID,
	)
	_check(
		_session.avatar_for(PLAYER_ID) != null,
		"and player %d, which is a different thing with the same number" % PLAYER_ID,
	)
	_look_straight_down_at(ITEM_GROUND)
	await get_tree().physics_frame
	await get_tree().physics_frame


func _test_the_picker_separates_an_item_from_the_ground() -> void:
	var centre := _viewport_centre()
	var on_item := _picker.pick(centre)
	_check(
		on_item["target"] == GroundPickerScript.Target.ITEM,
		"a cursor over an item resolves to the item, got target %d" % on_item["target"],
	)
	_check(
		on_item["item"] == _session.item_for(ITEM_ID),
		"and to the very body the registry holds for item %d" % ITEM_ID,
	)

	var beside := _picker.pick(centre + _beside_offset())
	_check(
		beside["target"] == GroundPickerScript.Target.GROUND,
		"a cursor beside it resolves to the ground, got target %d" % beside["target"],
	)

	var underneath = _picker.pick_ground(centre)
	_check(underneath != null, "and the ground under the item is still reachable")
	if underneath != null:
		var point: Vector2 = underneath
		_check(
			point.distance_to(ITEM_GROUND) < EXACT_EPSILON,
			"at %v, where the item lies, got %v" % [ITEM_GROUND, point],
		)


func _test_a_click_on_an_item_is_a_pickup_and_nothing_else() -> void:
	_watch()
	await _left_click(_viewport_centre())
	_check(
		_pickup_intents.size() == 1,
		"a click on an item sends one pickup, got %d" % _pickup_intents.size(),
	)
	_check(
		_pickup_intents.size() == 1 and _pickup_intents[0] == ITEM_ID,
		"naming item %d, got %s" % [ITEM_ID, _pickup_intents],
	)
	_check(
		_gather_intents.is_empty(),
		"and no gather, got %s" % [_gather_intents],
	)
	_check(
		_attack_intents.is_empty(),
		"and no attack, got %s" % [_attack_intents],
	)


func _test_a_click_on_bare_ground_beside_an_item_sends_nothing() -> void:
	_check(not _dock.visible, "the dock stays closed so a beside-cursor can reach the ground")
	var cursor := _viewport_centre() + _beside_offset()
	var beside := _picker.pick(cursor)
	_check(
		beside["target"] == GroundPickerScript.Target.GROUND,
		"the beside-cursor resolves to bare ground, got target %d" % beside["target"],
	)

	_watch()
	await _left_click(cursor)
	_check(
		_move_to_intents.is_empty(),
		"a click on bare ground sends no move_to, got %s" % [_move_to_intents],
	)
	_check(
		_pickup_intents.is_empty(),
		"and no pickup, got %s" % [_pickup_intents],
	)
	_check(
		_gather_intents.is_empty(),
		"and no gather, got %s" % [_gather_intents],
	)
	_check(
		_attack_intents.is_empty(),
		"and no attack, got %s" % [_attack_intents],
	)


func _test_a_pickup_click_changes_nothing_locally() -> void:
	_watch()
	await _left_click(_viewport_centre())
	_check(_pickup_intents.size() == 1, "the click was sent")
	_check(
		_session.item_for(ITEM_ID) != null,
		"and the body is still in the world, because no pickup is predicted",
	)
	_check(
		_panel.occupied_slot_count() == 0,
		"and no inventory slot was filled, got %d" % _panel.occupied_slot_count(),
	)

	await _feed('{"item_despawn":{"id":%d}}' % ITEM_ID)
	_check(
		_session.item_for(ITEM_ID) == null,
		"item_despawn is what removes it, and it did",
	)
	_check(
		_items_container.get_child_count() == 0,
		"leaving the container empty, got %d child(ren)" % _items_container.get_child_count(),
	)


func _test_an_unregistered_body_is_never_picked_up() -> void:
	var stray := GroundItemScene.instantiate() as GroundItemScript
	stray.name = "StrayItem"
	stray.configure(4242, "acorn")
	_items_container.add_child(stray)
	stray.place_at(ITEM_GROUND.x, ITEM_GROUND.y)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var resolved := _picker.pick(_viewport_centre())
	_check(
		resolved["target"] == GroundPickerScript.Target.ITEM,
		"the picker does resolve the stray body as an item",
	)

	_watch()
	await _left_click(_viewport_centre())
	_check(
		_pickup_intents.is_empty(),
		"but a body with no registry entry sends no pickup, got %s" % [_pickup_intents],
	)

	_watch()
	_session.request_pickup(4242)
	_check(
		_pickup_intents.is_empty(),
		"and asking for that id directly is refused too, got %s" % [_pickup_intents],
	)

	_items_container.remove_child(stray)
	stray.queue_free()


func _test_the_intents_match_the_protocol_byte_for_byte() -> void:
	_check(
		JSON.stringify(NetClientScript.pickup_frame(7)) == '{"pickup":{"item":7}}',
		'pickup is {"pickup":{"item":7}}, got %s'
		% JSON.stringify(NetClientScript.pickup_frame(7)),
	)
	_check(
		JSON.stringify(NetClientScript.gather_frame(1)) == '{"gather":{"node":1}}',
		'gather is {"gather":{"node":1}}, got %s'
		% JSON.stringify(NetClientScript.gather_frame(1)),
	)
	_check(
		JSON.stringify(NetClientScript.attack_frame(2)) == '{"attack":{"player":2}}',
		'attack is {"attack":{"player":2}}, got %s'
		% JSON.stringify(NetClientScript.attack_frame(2)),
	)
	_check(
		JSON.stringify(NetClientScript.drop_frame(3)) == '{"drop":{"slot":3}}',
		'drop is {"drop":{"slot":3}}, got %s' % JSON.stringify(NetClientScript.drop_frame(3)),
	)
	_check(
		JSON.stringify(NetClientScript.use_frame(3, 7)) == '{"use":{"on":7,"slot":3}}',
		'use is {"use":{"on":7,"slot":3}}, got %s' % JSON.stringify(NetClientScript.use_frame(3, 7)),
	)
	_check(
		JSON.stringify(NetClientScript.use_frame(3, 3)) == '{"use":{"on":3,"slot":3}}',
		'self-use is {"use":{"on":3,"slot":3}}, got %s'
		% JSON.stringify(NetClientScript.use_frame(3, 3)),
	)
	_check(
		JSON.stringify(NetClientScript.drop_frame(0)) == '{"drop":{"slot":0}}',
		"and slot 0 is a slot index like any other, got %s"
		% JSON.stringify(NetClientScript.drop_frame(0)),
	)


func _build_the_node_click_world() -> void:
	_dock.visible = false
	var toggle := _root.get_node_or_null("UI/InventoryToggle") as CanvasItem
	if toggle != null:
		toggle.visible = false
	await _feed(_welcome_frame())
	await _feed(
		'{"node_spawn":{"id":%d,"kind":"tree","x":%f,"z":%f,"state":"full"}}'
		% [NODE_ID, NODE_GROUND.x, NODE_GROUND.y]
	)
	_check(
		_session.node_for(NODE_ID) != null,
		"the world holds node %d for the gather click tests" % NODE_ID,
	)
	_check(_nodes_container != null, "ResourceNodes container is authored")
	_look_straight_down_at(NODE_GROUND)
	await get_tree().physics_frame
	await get_tree().physics_frame


func _test_the_picker_separates_a_node_from_the_ground() -> void:
	var centre := _viewport_centre()
	var on_node := _picker.pick(centre)
	_check(
		on_node["target"] == GroundPickerScript.Target.NODE,
		"a cursor over a node resolves to the node, got target %d" % on_node["target"],
	)
	_check(
		on_node["node"] == _session.node_for(NODE_ID),
		"and to the body the registry holds for node %d" % NODE_ID,
	)
	var beside := _picker.pick(centre + _beside_offset())
	_check(
		beside["target"] == GroundPickerScript.Target.GROUND,
		"a cursor beside it resolves to the ground, got target %d" % beside["target"],
	)


func _test_a_right_click_on_a_node_is_a_gather_and_nothing_else() -> void:
	_watch()
	await _right_click(_viewport_centre())
	_check(
		_gather_intents.size() == 1,
		"a right click on a node sends one gather, got %d" % _gather_intents.size(),
	)
	_check(
		_gather_intents.size() == 1 and _gather_intents[0] == NODE_ID,
		"naming node %d, got %s" % [NODE_ID, _gather_intents],
	)
	_check(_pickup_intents.is_empty(), "and no pickup, got %s" % [_pickup_intents])
	_check(_attack_intents.is_empty(), "and no attack, got %s" % [_attack_intents])


func _test_a_left_click_on_a_node_sends_no_gather() -> void:
	_watch()
	await _left_click(_viewport_centre())
	_check(
		_gather_intents.is_empty(),
		"a left click on a node sends no gather, got %s" % [_gather_intents],
	)
	_check(
		_move_to_intents.is_empty(),
		"and no move_to, got %s" % [_move_to_intents],
	)
	_check(_pickup_intents.is_empty(), "and no pickup, got %s" % [_pickup_intents])
	_check(_attack_intents.is_empty(), "and no attack, got %s" % [_attack_intents])


func _test_a_click_on_bare_ground_beside_a_node_sends_nothing() -> void:
	var cursor := _viewport_centre() + _beside_offset()
	var beside := _picker.pick(cursor)
	_check(
		beside["target"] == GroundPickerScript.Target.GROUND,
		"the beside-cursor resolves to bare ground, got target %d" % beside["target"],
	)

	_watch()
	await _left_click(cursor)
	_check(
		_move_to_intents.is_empty(),
		"a click on bare ground sends no move_to, got %s" % [_move_to_intents],
	)
	_check(_gather_intents.is_empty(), "and no gather, got %s" % [_gather_intents])
	_check(_pickup_intents.is_empty(), "and no pickup, got %s" % [_pickup_intents])
	_check(_attack_intents.is_empty(), "and no attack, got %s" % [_attack_intents])


func _test_a_click_on_an_item_still_picks_up_beside_a_node() -> void:
	await _feed(
		'{"item_spawn":{"id":%d,"kind":"acorn","x":%f,"z":%f}}'
		% [ITEM_ID, ITEM_GROUND.x, ITEM_GROUND.y]
	)
	_look_straight_down_at(ITEM_GROUND)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_watch()
	await _left_click(_viewport_centre())
	_check(
		_pickup_intents.size() == 1 and _pickup_intents[0] == ITEM_ID,
		"a click on an item still sends pickup, got %s" % [_pickup_intents],
	)
	_check(_gather_intents.is_empty(), "and gather does not steal it, got %s" % [_gather_intents])
	_check(_attack_intents.is_empty(), "and no attack, got %s" % [_attack_intents])


func _build_the_player_click_world() -> void:
	_dock.visible = false
	var toggle := _root.get_node_or_null("UI/InventoryToggle") as CanvasItem
	if toggle != null:
		toggle.visible = false
	await _feed(
		(
			'{"welcome":{"you":%d,"tick_ms":150,"tick":900,"players":['
			+ '{"id":%d,"x":0.0,"z":0.0},'
			+ '{"id":%d,"x":%f,"z":%f}'
			+ '],"items":[]}}'
		)
		% [PLAYER_ID, PLAYER_ID, REMOTE_PLAYER_ID, REMOTE_GROUND.x, REMOTE_GROUND.y]
	)
	_check(
		_session.avatar_for(REMOTE_PLAYER_ID) != null,
		"the world holds remote player %d for the select click tests" % REMOTE_PLAYER_ID,
	)
	_check(_remotes_container != null, "RemotePlayers container is authored")
	_look_straight_down_at(REMOTE_GROUND)
	await get_tree().physics_frame
	await get_tree().physics_frame


func _test_the_picker_separates_a_player_from_the_ground() -> void:
	var centre := _viewport_centre()
	var on_player := _picker.pick(centre)
	_check(
		on_player["target"] == GroundPickerScript.Target.PLAYER,
		"a cursor over a player resolves to the player, got target %d" % on_player["target"],
	)
	_check(
		on_player["player"] == _session.avatar_for(REMOTE_PLAYER_ID),
		"and to the body the registry holds for player %d" % REMOTE_PLAYER_ID,
	)
	var beside := _picker.pick(centre + _beside_offset())
	_check(
		beside["target"] == GroundPickerScript.Target.GROUND,
		"a cursor beside it resolves to the ground, got target %d" % beside["target"],
	)


func _test_a_click_on_a_remote_player_selects_and_does_not_attack() -> void:
	_watch()
	await _left_click(_viewport_centre())
	_check(
		_session.selected_player_id() == REMOTE_PLAYER_ID,
		"a left click on a remote player selects them, got %d" % _session.selected_player_id(),
	)
	_check(
		_selection_events.size() == 1 and _selection_events[0] == REMOTE_PLAYER_ID,
		"and emits selection_changed once, got %s" % [_selection_events],
	)
	var remote: PlayerAvatarScript = _session.avatar_for(REMOTE_PLAYER_ID)
	_check(remote != null and remote.is_selected(), "with the selection ring visible")
	_check(_attack_intents.is_empty(), "and no attack, got %s" % [_attack_intents])
	_check(_pickup_intents.is_empty(), "and no pickup, got %s" % [_pickup_intents])
	_check(_gather_intents.is_empty(), "and no gather, got %s" % [_gather_intents])


func _test_a_click_on_self_is_not_a_selection() -> void:
	_session.clear_selection()
	_look_straight_down_at(Vector2.ZERO)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var on_self := _picker.pick(_viewport_centre())
	_check(
		on_self["target"] == GroundPickerScript.Target.PLAYER,
		"a cursor over self resolves to the player body, got target %d" % on_self["target"],
	)
	_check(
		on_self["player"] == _session.avatar_for(PLAYER_ID),
		"and to this client's own avatar",
	)

	_watch()
	await _left_click(_viewport_centre())
	_check(
		_session.selected_player_id() == 0,
		"a click on self leaves selection empty, got %d" % _session.selected_player_id(),
	)
	_check(_selection_events.is_empty(), "and emits no selection_changed")
	_check(_attack_intents.is_empty(), "and no attack, got %s" % [_attack_intents])
	_check(_pickup_intents.is_empty(), "and no pickup, got %s" % [_pickup_intents])
	_check(_gather_intents.is_empty(), "and no gather, got %s" % [_gather_intents])

	_look_straight_down_at(REMOTE_GROUND)
	await get_tree().physics_frame
	await get_tree().physics_frame


func _test_a_ground_click_leaves_the_selection_alone() -> void:
	_watch()
	await _left_click(_viewport_centre())
	_check(
		_session.selected_player_id() == REMOTE_PLAYER_ID,
		"precondition: remote is selected, got %d" % _session.selected_player_id(),
	)

	var cursor := _viewport_centre() + _beside_offset()
	var beside := _picker.pick(cursor)
	_check(
		beside["target"] == GroundPickerScript.Target.GROUND,
		"the beside-cursor resolves to bare ground, got target %d" % beside["target"],
	)

	_watch()
	await _left_click(cursor)
	_check(
		_session.selected_player_id() == REMOTE_PLAYER_ID,
		"and a click on that ground leaves the selection standing, got %d"
		% _session.selected_player_id(),
	)
	_check(_selection_events.is_empty(), "with no selection_changed")
	_check(
		_move_to_intents.is_empty(),
		"and no move_to, got %s" % [_move_to_intents],
	)
	_check(_attack_intents.is_empty(), "and no attack, got %s" % [_attack_intents])
	_check(_pickup_intents.is_empty(), "and no pickup, got %s" % [_pickup_intents])
	_check(_gather_intents.is_empty(), "and no gather, got %s" % [_gather_intents])


func _test_escape_clears_player_selection() -> void:
	_check(
		_session.selected_player_id() == REMOTE_PLAYER_ID,
		"precondition: remote still selected before Escape",
	)
	_watch()
	var viewport := _camera.get_viewport()
	var cancel := InputEventKey.new()
	cancel.keycode = KEY_ESCAPE
	cancel.physical_keycode = KEY_ESCAPE
	cancel.pressed = true
	viewport.push_input(cancel)
	await get_tree().process_frame

	_check(_session.selected_player_id() == 0, "Escape clears the tab target")
	_check(
		_selection_events.size() == 1 and _selection_events[0] == 0,
		"and emits selection_changed(0), got %s" % [_selection_events],
	)
	var remote: PlayerAvatarScript = _session.avatar_for(REMOTE_PLAYER_ID)
	_check(remote != null and not remote.is_selected(), "and hides the selection ring")
	_check(_attack_intents.is_empty(), "and sends no attack")


func _test_a_right_click_on_a_remote_player_is_an_attack() -> void:
	_look_straight_down_at(REMOTE_GROUND)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_session.clear_selection()
	_watch()
	await _right_click(_viewport_centre())
	_check(
		_attack_intents.size() == 1,
		"a right click on a remote player sends one attack, got %d" % _attack_intents.size(),
	)
	_check(
		_attack_intents.size() == 1 and _attack_intents[0] == REMOTE_PLAYER_ID,
		"naming player %d, got %s" % [REMOTE_PLAYER_ID, _attack_intents],
	)
	_check(
		_session.selected_player_id() == REMOTE_PLAYER_ID,
		"and selects the clicked target, got %d" % _session.selected_player_id(),
	)


func _test_clicking_an_occupied_slot_uses_it() -> void:
	var last := WIRE_SIZE - 1
	_dock.visible = true
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":0,"kind":"logs"},{"slot":%d,"kind":"logs"}]}}'
		% [WIRE_SIZE, last]
	)
	_check(_dock.visible, "a dock with slots in it is drawn")

	_watch()
	await _click_slot(last)
	_check(_use_intents.is_empty(), "the first click selects and sends no use yet")
	_check(_drop_intents.is_empty(), "and sends no drop either, got %s" % [_drop_intents])
	_check(_session.has_pending_use(), "with a pending use selection")

	await _click_slot(last)
	_check(
		_use_intents.size() == 1 and _use_intents[0] == Vector2i(last, last),
		"the second click on slot %d sends use on itself, got %s" % [last, _use_intents],
	)
	_check(_drop_intents.is_empty(), "and still no drop")
	_check(not _session.has_pending_use(), "and the selection is spent")

	_check(
		_panel.kind_in_slot(last) == "logs",
		"and the panel still shows the item, because a use is not predicted",
	)
	_check(
		_panel.occupied_slot_count() == 2,
		"nor is anything else, got %d occupied" % _panel.occupied_slot_count(),
	)

	var small := 4
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":%d,"kind":"logs"},{"slot":%d,"kind":"acorn"}]}}'
		% [small, small - 2, small - 1]
	)
	_watch()
	_panel.slot_activated.emit(small - 2)
	_panel.slot_activated.emit(small - 1)
	_check(
		_use_intents.size() == 1 and _use_intents[0] == Vector2i(small - 2, small - 1),
		"activating %d then %d in an inventory of %d names those indices, got %s"
		% [small - 2, small - 1, small, _use_intents],
	)

	await _feed('{"inventory":{"size":%d,"slots":[]}}' % small)
	_check(
		_panel.occupied_slot_count() == 0,
		"the inventory the server sends back is what empties the slots, got %d occupied"
		% _panel.occupied_slot_count(),
	)


func _test_cancel_clears_use_selection() -> void:
	var last := WIRE_SIZE - 1
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":%d,"kind":"logs"}]}}' % [WIRE_SIZE, last]
	)
	_watch()
	await _click_slot(last)
	_check(_session.has_pending_use(), "a first click leaves a pending selection")

	var viewport := _camera.get_viewport()
	var cancel := InputEventKey.new()
	cancel.keycode = KEY_ESCAPE
	cancel.physical_keycode = KEY_ESCAPE
	cancel.pressed = true
	viewport.push_input(cancel)
	await get_tree().process_frame

	_check(not _session.has_pending_use(), "escape clears the pending selection")
	_check(_use_intents.is_empty(), "and sends no use, got %s" % [_use_intents])
	_check(_drop_intents.is_empty(), "and no drop either")

	_watch()
	_check(_session.clear_use_selection() == false, "clearing idle is a no-op")
	await _click_slot(last)
	_check(_session.has_pending_use(), "a fresh first click selects again")
	_check(_session.clear_use_selection(), "and clear_use_selection drops it")
	_check(not _session.has_pending_use(), "leaving no pending selection")
	_check(_use_intents.is_empty(), "without sending use")


func _test_clicking_an_empty_slot_uses_nothing() -> void:
	_dock.visible = true
	await _feed('{"inventory":{"size":4,"slots":[]}}')
	_watch()
	await _click_slot(3)
	_check(
		_use_intents.is_empty() and _drop_intents.is_empty(),
		"clicking an empty slot sends no use and no drop, got use %s drop %s"
		% [_use_intents, _drop_intents],
	)

	_watch()
	_session.request_drop(-1)
	_check(_drop_intents.is_empty(), "and a negative slot index is refused outright")
	_session.request_use(-1, 0)
	_check(_use_intents.is_empty(), "as is a negative use slot")


func _test_shift_clicking_an_occupied_slot_drops_it() -> void:
	var last := WIRE_SIZE - 1
	_dock.visible = false
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":%d,"kind":"acorn"}]}}' % [WIRE_SIZE, last]
	)
	var closed := _panel.slot_at(last)
	_check(closed != null, "the panel draws slot %d while the bag is still closed" % last)
	if closed != null:
		_check(
			closed.get_global_rect().has_area() and not closed.is_visible_in_tree(),
			"with a laid-out rect %s but no visibility in the tree, so the viewport skips it "
			% closed.get_global_rect()
			+ "for input and a click at that centre reaches nothing at all",
		)

	_press_toggle_inventory()
	_check(_dock.visible, "the toggle_inventory action opens the bag on the frame it is pressed")

	_watch()
	await _click_slot(last, true)
	_check(
		_drop_intents.size() == 1 and _drop_intents[0] == last,
		"shift-clicking occupied slot %d sends exactly one drop naming it, got %s"
		% [last, _drop_intents],
	)
	_check(_use_intents.is_empty(), "and no use, got %s" % [_use_intents])
	_check(
		not _session.has_pending_use(),
		"and leaves no pending use selection, so the next plain click starts a fresh one",
	)
	_check(
		_panel.kind_in_slot(last) == "acorn",
		"and the panel still shows the item, because a drop is not predicted",
	)

	_watch()
	await _click_slot(last)
	_check(
		_session.has_pending_use() and _drop_intents.is_empty(),
		"while a plain click on that same slot still starts a use, got drop %s" % [_drop_intents],
	)
	_check(_session.clear_use_selection(), "which clears again")

	await _feed('{"inventory":{"size":%d,"slots":[]}}' % WIRE_SIZE)
	_watch()
	await _click_slot(last, true)
	_check(
		_drop_intents.is_empty(),
		"shift-clicking that slot once it is empty drops nothing, got %s" % [_drop_intents],
	)
	_dock.visible = false


func _test_clicking_the_panel_chrome_reaches_nothing() -> void:
	await _feed(_inventory_frame(WIRE_SIZE, 1))
	await _check_the_chrome_is_a_wall("carrying one item")

	await _feed(_inventory_frame(WIRE_SIZE, 0))
	_check(
		_panel.occupied_slot_count() == 0,
		"the join-state panel is drawn holding nothing, got %d occupied"
		% _panel.occupied_slot_count(),
	)
	await _check_the_chrome_is_a_wall("holding nothing, as at join")


func _check_the_chrome_is_a_wall(state: String) -> void:
	_dock.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_dock.visible, "the full-size dock is drawn (%s)" % state)

	var screen := _camera.get_viewport().get_visible_rect()
	var panel_rect := _dock.get_global_rect()
	print("INTERACTION panel rect %s in viewport %s (%s)" % [panel_rect, screen.size, state])

	var chrome: Variant = _panel_chrome_point(panel_rect, screen)
	_check(chrome != null, "the dock draws chrome inside the viewport to click on (%s)" % state)
	if chrome == null:
		return
	var at: Vector2 = chrome

	var under: Variant = _picker.pick_ground(at)
	_check(under != null, "there is ground under %v to stand an item on (%s)" % [at, state])
	if under == null:
		return
	var here: Vector2 = under
	await _feed(
		'{"item_spawn":{"id":%d,"kind":"acorn","x":%f,"z":%f}}'
		% [CHROME_ITEM_ID, here.x, here.y]
	)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var resolved := _picker.pick(at)
	_check(
		resolved["target"] == GroundPickerScript.Target.ITEM,
		"and item %d stands on it, so a click that got through would pick it up (%s), got target %d"
		% [CHROME_ITEM_ID, state, resolved["target"]],
	)

	_watch()
	await _left_click(at)
	_check(
		_pickup_intents.is_empty(),
		"but a click on the panel's chrome at %v sends no pickup (%s), got %s"
		% [at, state, _pickup_intents],
	)
	_check(
		_drop_intents.is_empty() and _use_intents.is_empty(),
		"and no drop or use either (%s): chrome is not a control, it is a wall" % state,
	)

	_dock.visible = false
	await get_tree().process_frame
	_watch()
	await _left_click(at)
	_check(
		_pickup_intents.size() == 1 and _pickup_intents[0] == CHROME_ITEM_ID,
		"while the very same click with the dock hidden picks item %d up (%s), got %s"
		% [CHROME_ITEM_ID, state, _pickup_intents],
	)

	_dock.visible = true
	await _feed('{"item_despawn":{"id":%d}}' % CHROME_ITEM_ID)


func _panel_chrome_point(panel_rect: Rect2, screen: Rect2) -> Variant:
	var slots: Array[Rect2] = []
	for index in _panel.slot_count():
		var slot := _panel.slot_at(index)
		if slot != null:
			slots.append(slot.get_global_rect())

	for inset: Vector2 in [Vector2(4, 4), Vector2(4, 20), Vector2(20, 4), Vector2(20, 20)]:
		var candidate := panel_rect.end - inset
		if not screen.has_point(candidate) or not panel_rect.has_point(candidate):
			continue
		var on_slot := false
		for rect in slots:
			if rect.has_point(candidate):
				on_slot = true
				break
		if not on_slot:
			return candidate
	return null


func _test_the_scripted_feed_still_builds_a_world() -> void:
	var feeder := MainScene.instantiate() as Node3D
	feeder.name = "FeedClient"
	_world.add_child(feeder)
	await get_tree().process_frame

	var fed: int = feeder._feed_scripted_frames(["--feed", FEED_FIXTURE])
	_check(
		fed == FEED_FIXTURE_FRAMES,
		"the feed offers %d frame(s) from the fixture, got %d" % [FEED_FIXTURE_FRAMES, fed],
	)

	var session := feeder.get_node("Session") as SessionScript
	var panel := feeder.get_node("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	_check(
		session.known_item_ids().size() == FEED_FIXTURE_ITEMS,
		"and they build %d item body(s), got %d"
		% [FEED_FIXTURE_ITEMS, session.known_item_ids().size()],
	)
	_check(
		session.known_ids().size() == FEED_FIXTURE_PLAYERS,
		"and %d player body(s), got %d"
		% [FEED_FIXTURE_PLAYERS, session.known_ids().size()],
	)
	_check(
		panel.slot_count() == FEED_FIXTURE_SLOTS,
		"and an inventory of %d slots, got %d" % [FEED_FIXTURE_SLOTS, panel.slot_count()],
	)
	_check(
		panel.occupied_slot_count() == FEED_FIXTURE_OCCUPIED,
		"with %d of them occupied, got %d"
		% [FEED_FIXTURE_OCCUPIED, panel.occupied_slot_count()],
	)
	_check(
		feeder._feed_scripted_frames([]) == 0,
		"and no --feed flag feeds nothing rather than failing",
	)

	_world.remove_child(feeder)
	feeder.queue_free()


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


func _watch() -> void:
	_move_to_intents.clear()
	_pickup_intents.clear()
	_gather_intents.clear()
	_attack_intents.clear()
	_selection_events.clear()
	_drop_intents.clear()
	_use_intents.clear()


func _left_click(screen_position: Vector2) -> void:
	var viewport := _camera.get_viewport()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = screen_position
	viewport.push_input(press)
	await get_tree().process_frame


func _right_click(screen_position: Vector2) -> void:
	var viewport := _camera.get_viewport()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	press.position = screen_position
	viewport.push_input(press)
	await get_tree().process_frame


func _click_slot(index: int, shift := false) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var slot := _panel.slot_at(index)
	_check(slot != null, "the panel is drawing slot %d to click" % index)
	if slot == null:
		return
	var viewport := slot.get_viewport()
	var rect := slot.get_global_rect()
	var centre := rect.get_center()
	_check(
		rect.has_area() and viewport.get_visible_rect().has_point(centre),
		"and slot %d is laid out somewhere clickable (%s in a %s viewport)"
		% [index, rect, viewport.get_visible_rect()],
	)

	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.shift_pressed = shift
		event.position = centre
		viewport.push_input(event)
	await get_tree().process_frame


func _press_toggle_inventory() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_I
	event.pressed = true
	_camera.get_viewport().push_input(event)


func _look_straight_down_at(ground: Vector2) -> void:
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)),
		Vector3(ground.x, CAMERA_HEIGHT, ground.y),
	)


func _viewport_centre() -> Vector2:
	return _camera.get_viewport().get_visible_rect().size * 0.5


func _beside_offset() -> Vector2:
	return Vector2(_camera.get_viewport().get_visible_rect().size.y * OFFSET_FRACTION, 0.0)


static func _inventory_frame(size: int, occupied: int) -> String:
	var slots := PackedStringArray()
	for index in occupied:
		slots.append('{"slot":%d,"kind":"acorn"}' % index)
	return '{"inventory":{"size":%d,"slots":[%s]}}' % [size, ",".join(slots)]


static func _welcome_frame() -> String:
	return (
		'{"welcome":{"you":%d,"tick_ms":150,"tick":900,"players":[{"id":%d,"x":0.0,"z":0.0}],'
		% [PLAYER_ID, PLAYER_ID]
		+ '"items":[]}}'
	)


func _is_color(actual: Color, expected: Color) -> bool:
	return (
		absf(actual.r - expected.r) <= CHANNEL_EPSILON
		and absf(actual.g - expected.g) <= CHANNEL_EPSILON
		and absf(actual.b - expected.b) <= CHANNEL_EPSILON
	)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
