extends Node3D

## What a click means, and what the inventory panel draws. **M1d.**
##
## [b]No server.[/b] Every frame here is handed to `main.tscn`'s own decoder
## through `net_client.gd`'s public [code]ingest_text_frame[/code], and every
## click is a real [InputEventMouseButton] pushed through a real viewport. So
## this suite is green before M1's Go half answers a `pickup`, and it stays
## green independently of it. That is what makes the client half of M1
## verifiable on its own.
##
## The thing under test is `main.tscn` itself, so every assertion is about the
## scene the game ships rather than a rig assembled for the occasion.
##
## [b]Two assertions here are the unit's actual claim[/b], and they are written
## as each other's negative: a click on an item produces a `pickup` and no
## `move_to`, and a click on bare ground produces a `move_to` and no `pickup`.
## Either one alone passes for a client that always sends the same intent.
##
## [b]What this suite cannot prove.[/b] It observes the intents `session.gd`
## emits, not bytes leaving a socket, because there is no socket. The wire form
## of both intents is asserted against `net_client.gd`'s public static frame
## builders, which is the same seam M1c used. End-to-end `pickup` needs M1a's
## server and end-to-end `drop` needs M1b's, and both belong to M1e.

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const GroundItemScene := preload("res://scenes/ground_item.tscn")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const Assertions := preload("res://tests/assertions.gd")

## The scripted world the screenshot is captured from. Driven here as well so
## that a break in the `--feed` path fails a test run rather than waiting for
## the next time somebody looks at a PNG. **M1c left this uncovered.**
const FEED_FIXTURE := "res://tests/fixtures/screenshot_world.ndjson"
const FEED_FIXTURE_FRAMES := 2
const FEED_FIXTURE_ITEMS := 2
const FEED_FIXTURE_PLAYERS := 1
const FEED_FIXTURE_SLOTS := 28
const FEED_FIXTURE_OCCUPIED := 3

## RuneScape's number, and the one the fixtures below state on the wire. Named
## here so that "the panel drew what the frame said" cannot accidentally become
## "the panel drew what the test hardcoded": the sizes actually asserted are
## read back from the frames, and one of them is deliberately not this.
const WIRE_SIZE := 28

## A size no inventory in this game has, sent to prove the panel draws the grid
## the wire describes rather than a grid it was built with.
const ODD_SIZE := 6

## Where the item under the test camera lies. Off the origin so that a bug that
## always answers (0, 0) cannot pass.
const ITEM_GROUND := Vector2(5.0, 8.0)

## The item id the click resolves to, and the player id sharing its number.
## Item ids and player ids are separate spaces (PROTOCOL.md, "Identity"), so a
## world holding both is the case that catches a client keying them together.
const ITEM_ID := 3
const PLAYER_ID := 3

## Camera height for the click tests. High enough that the whole viewport is
## ground, so a click that misses the item lands on the ground rather than the
## sky.
const CAMERA_HEIGHT := 20.0

## How far from screen centre a cursor has to be to be beside the item rather
## than on it, as a fraction of the viewport's [b]height[/b].
##
## A fraction and not a pixel count, because the headless viewport is 64x64 and
## the shipped window is 1280x720: a constant in pixels is several world units
## in one and off the edge of the world in the other. The camera keeps its
## vertical field of view, so a fraction of the height is the same angle at
## either size. At [constant CAMERA_HEIGHT] this lands about 5.8 units away,
## and the item is half a unit wide.
const OFFSET_FRACTION := 0.25

## Tolerance for a coordinate that should be exact.
const EXACT_EPSILON := 0.01

## Green is Pickup, magenta is missing-asset, gray is inert (NOTES.md, "Color as
## semantics"). Compared channel by channel within this, which is wide enough to
## survive a tweak to the exact shade and narrow enough that no two of the three
## can pass for each other.
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
var _grid: GridContainer = null
var _items_container: Node3D = null

## Every intent the session emitted since the last [method _watch] call.
var _move_to_intents := PackedVector2Array()
var _pickup_intents := PackedInt32Array()
var _drop_intents := PackedInt32Array()


## Suite contract, polled by `run_tests.gd`. Reports; never quits.
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
	_panel = _root.get_node("UI/InventoryPanel") as InventoryPanelScript
	_grid = _root.get_node("UI/InventoryPanel/Margin/Rows/Slots") as GridContainer
	_items_container = _root.get_node("GroundItems") as Node3D

	# The rig chases its target every frame and would undo the camera placement
	# the click tests depend on. Switched off rather than fought.
	var rig := _root.get_node("CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	_session.move_to_requested.connect(func(x: float, z: float) -> void:
		_move_to_intents.append(Vector2(x, z))
	)
	_session.pickup_requested.connect(func(id: int) -> void: _pickup_intents.append(id))
	_session.drop_requested.connect(func(slot: int) -> void: _drop_intents.append(slot))

	# main.tscn's Session resolves its exported node paths in _ready, and a
	# suite that asserts before that reads nulls that look like scene bugs. The
	# physics space also has to have stepped before any ray can hit anything.
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
	await _test_a_click_on_an_item_is_a_pickup_and_not_a_move()
	await _test_a_click_on_bare_ground_is_a_move_and_not_a_pickup()
	await _test_a_pickup_click_changes_nothing_locally()
	await _test_an_unregistered_body_is_never_picked_up()
	_test_the_intents_match_the_protocol_byte_for_byte()

	await _test_clicking_an_occupied_slot_drops_it()
	await _test_clicking_an_empty_slot_drops_nothing()
	await _test_clicking_the_panel_chrome_reaches_nothing()

	await _test_the_scripted_feed_still_builds_a_world()

	print(
		"INTERACTION RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


# --------------------------------------------------------------------------
# The panel.
# --------------------------------------------------------------------------


## CLAUDE.md, "Scene authoring": there is one inventory panel per world, so the
## panel, its heading and its grid are authored in `main.tscn`. A `_ready` that
## built them would be a scene edit written in the wrong language.
func _test_the_panel_is_authored() -> void:
	_check(_panel != null, "main.tscn authors an inventory panel running inventory_panel.gd")
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
		_panel != null and not _panel.visible,
		"and is not drawn at all until then, so it cannot sit in front of the world"
		+ " swallowing clicks while the client is uninformed",
	)
	_check(
		_grid != null and _grid.columns > 0,
		"and the grid's column count is authored, not computed (%d)"
		% [0 if _grid == null else _grid.columns],
	)
	# The panel is opaque (M1k), and exactly one node makes it so: the panel
	# stops, its containers stay IGNORE. A container that stopped too would work
	# today and would move the boundary the next time the tree changed shape, so
	# where a click stops stays a property of the panel alone.
	_check(
		_panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and the panel stops every click inside its rect, got filter %d" % _panel.mouse_filter,
	)
	for chrome in [_panel.get_node("Margin"), _panel.get_node("Margin/Rows"), _grid]:
		var control := chrome as Control
		_check(
			control != null and control.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"and %s hands a missed click down to the panel rather than catching it"
			% [null if control == null else control.name],
		)


## `inventory` with an empty `slots` still draws the whole grid: `size` is how
## many slots exist and `slots` is only what is in them (PROTOCOL.md).
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


## One occupied slot, drawn green, with every other slot still empty.
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


## `size` occupied slots: the maximum the contract allows, and the case where
## sparse and dense agree.
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


## `inventory` is a full restatement, never a patch (PROTOCOL.md), so a second
## one replaces the first rather than merging with it. Fed straight after the
## full inventory above, so a panel that patched would still show 28.
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


## Slot 0 and slot `size - 1`: the two indices an off-by-one gets wrong.
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


## `size` is on the wire so the client draws the grid it is told to draw rather
## than hardcoding a second copy of RuneScape's 28 (PROTOCOL.md, `inventory`).
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
	_check(not _panel.visible, "and a panel with no slots is hidden rather than drawn empty")


## An item kind this client has no art for still shows something, and it screams
## (NOTES.md, "Color as semantics"). This is the path that has to work when a
## server learns a second kind before this client does.
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


## `welcome` restates the world and the inventory is not part of it: it arrives
## as its own message inside the same atomic step (PROTOCOL.md, `welcome`).
func _test_welcome_empties_the_panel() -> void:
	await _feed(_welcome_frame())
	_check(
		_panel.slot_count() == 0,
		"welcome empties the panel rather than leaving a stale one up, got %d slots"
		% _panel.slot_count(),
	)
	_check(_grid.get_child_count() == 0, "and empties the authored grid with it")
	_check(
		not _panel.visible,
		"and takes the panel down with it, so the world behind it is clickable again",
	)


# --------------------------------------------------------------------------
# The click.
# --------------------------------------------------------------------------


## A world holding player %d and item %d at once, with the camera looking
## straight down at the item.
func _build_the_click_world() -> void:
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
	# The body was added this frame; the physics space has to step before any
	# ray can find it, and a query before that looks exactly like a broken one.
	await get_tree().physics_frame
	await get_tree().physics_frame


## One ray, both layers, nearest surface wins. Asserted through the picker's own
## resolver before any click is pushed, so a failure here says "the raycast is
## wrong" rather than "something in the click path is wrong".
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

	# The same cursor, asked the other question: pick_ground() queries the
	# ground layer alone, so it answers with the ground underneath the item.
	var underneath = _picker.pick_ground(centre)
	_check(underneath != null, "and the ground under the item is still reachable")
	if underneath != null:
		var point: Vector2 = underneath
		_check(
			point.distance_to(ITEM_GROUND) < EXACT_EPSILON,
			"at %v, where the item lies, got %v" % [ITEM_GROUND, point],
		)


## [b]The unit's claim, half one.[/b] Fails if a click on an item produced a
## `move_to`.
func _test_a_click_on_an_item_is_a_pickup_and_not_a_move() -> void:
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
		_move_to_intents.is_empty(),
		"and no move_to, got %s" % [_move_to_intents],
	)


## [b]The unit's claim, half two.[/b] Fails if a click on bare ground produced a
## `pickup`.
func _test_a_click_on_bare_ground_is_a_move_and_not_a_pickup() -> void:
	var cursor := _viewport_centre() + _beside_offset()
	var expected = _picker.pick_ground(cursor)
	_check(expected != null, "the bare-ground cursor resolves to a ground point")

	_watch()
	await _left_click(cursor)
	_check(
		_move_to_intents.size() == 1,
		"a click on bare ground sends one move_to, got %d" % _move_to_intents.size(),
	)
	if _move_to_intents.size() == 1 and expected != null:
		var here: Vector2 = expected
		_check(
			_move_to_intents[0].distance_to(here) < EXACT_EPSILON,
			"carrying the point the ray landed on, %v, got %v" % [here, _move_to_intents[0]],
		)
	_check(
		_pickup_intents.is_empty(),
		"and no pickup, got %s" % [_pickup_intents],
	)


## The client is a cache with zero authority (CLAUDE.md), so a pickup click
## changes nothing locally. The body leaves when `item_despawn` says it did.
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


## An id the server never named never reaches the wire. The body below is a real
## `ground_item.tscn` with a real id painted on it and no registry entry, which
## is exactly what a client that read the id off the node would happily send.
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
	_check(
		_move_to_intents.is_empty(),
		"and does not fall through to a move_to either, got %s" % [_move_to_intents],
	)

	_watch()
	_session.request_pickup(4242)
	_check(
		_pickup_intents.is_empty(),
		"and asking for that id directly is refused too, got %s" % [_pickup_intents],
	)

	_items_container.remove_child(stray)
	stray.queue_free()


## The exact bytes both intents put on the wire, against PROTOCOL.md. Asserted
## from `net_client.gd`'s public static builders, which is the only way to check
## a sender before the server that answers it exists.
func _test_the_intents_match_the_protocol_byte_for_byte() -> void:
	_check(
		JSON.stringify(NetClientScript.pickup_frame(7)) == '{"pickup":{"item":7}}',
		'pickup is {"pickup":{"item":7}}, got %s'
		% JSON.stringify(NetClientScript.pickup_frame(7)),
	)
	_check(
		JSON.stringify(NetClientScript.drop_frame(3)) == '{"drop":{"slot":3}}',
		'drop is {"drop":{"slot":3}}, got %s' % JSON.stringify(NetClientScript.drop_frame(3)),
	)
	_check(
		JSON.stringify(NetClientScript.drop_frame(0)) == '{"drop":{"slot":0}}',
		"and slot 0 is a slot index like any other, got %s"
		% JSON.stringify(NetClientScript.drop_frame(0)),
	)


# --------------------------------------------------------------------------
# The drop.
# --------------------------------------------------------------------------


## A real click on an occupied slot, pushed through the viewport, becomes a
## `drop` naming that slot's index and nothing else.
##
## [b]The slot clicked is the last one[/b], for a reason that is about the test
## environment and not about the game: the headless viewport is 64x64 while the
## shipped window is 1280x720, and a 28-slot panel anchored to the bottom-right
## corner has only its last cell inside a 64x64 rect. A [Control] does receive a
## press outside the viewport — M1k probed that and an off-screen slot consumed
## one — but it fires no [signal BaseButton.pressed] when it does, so the last
## cell is the one a real click can drop from here. Two different sizes are used
## so that the index is genuinely read from the slot rather than being the only
## number available.
func _test_clicking_an_occupied_slot_drops_it() -> void:
	var last := WIRE_SIZE - 1
	await _feed(
		'{"inventory":{"size":%d,"slots":[{"slot":0,"kind":"acorn"},{"slot":%d,"kind":"acorn"}]}}'
		% [WIRE_SIZE, last]
	)
	_check(_panel.visible, "a panel with slots in it is drawn")

	_watch()
	await _click_slot(last)
	_check(
		_drop_intents.size() == 1 and _drop_intents[0] == last,
		"clicking slot %d sends one drop naming slot %d, got %s" % [last, last, _drop_intents],
	)
	_check(
		_move_to_intents.is_empty() and _pickup_intents.is_empty(),
		"and the click never reaches the world behind the panel",
	)

	_check(
		_panel.kind_in_slot(last) == "acorn",
		"and the panel still shows the item, because a drop is not predicted",
	)
	_check(
		_panel.occupied_slot_count() == 2,
		"nor is anything else, got %d occupied" % _panel.occupied_slot_count(),
	)

	# A different size, so the last slot is a different index. A panel that
	# reported one hardcoded number would pass one of these two and not both.
	var small := 4
	await _feed(_inventory_frame(small, small))
	_watch()
	await _click_slot(small - 1)
	_check(
		_drop_intents.size() == 1 and _drop_intents[0] == small - 1,
		"in an inventory of %d, clicking the last slot names %d, got %s"
		% [small, small - 1, _drop_intents],
	)

	# What the server says is what changes it.
	await _feed('{"inventory":{"size":%d,"slots":[]}}' % small)
	_check(
		_panel.occupied_slot_count() == 0,
		"the inventory the server sends back is what empties the slot, got %d occupied"
		% _panel.occupied_slot_count(),
	)


## An empty slot names nothing to drop, and the server would refuse an intent
## that said otherwise.
##
## Driven through the same real click as the test above, on the same widget, in
## the same place: the only thing that changed is what the server said is in it.
func _test_clicking_an_empty_slot_drops_nothing() -> void:
	_watch()
	await _click_slot(3)
	_check(
		_drop_intents.is_empty(),
		"clicking an empty slot sends no drop, got %s" % [_drop_intents],
	)
	_check(
		_move_to_intents.is_empty() and _pickup_intents.is_empty(),
		"and does not fall through to the world behind it",
	)

	_watch()
	_session.request_drop(-1)
	_check(_drop_intents.is_empty(), "and a negative slot index is refused outright")


## [b]The M1k claim.[/b] A click on the panel's chrome sends nothing at all.
##
## The shipped panel used to behave three ways depending on where you hit it:
## an occupied slot dropped, an empty slot ate the click, and the chrome walked
## your character, because everything but the slots was
## [constant Control.MOUSE_FILTER_IGNORE] so the world showed through. Only the
## first was designed. RuneScape's sidebar is opaque, so all three collapse into
## one rule and this is the test of it.
##
## [b]Both inventory states, and the empty one is the load-bearing case.[/b]
## Every player joins holding nothing, so an inventory of 28 empty slots is what
## the panel spends most of its life drawing, and Linear ARM-40 names that
## state as the exposure. An earlier version of this test fed one occupied slot
## and nothing else, which left the join state untested: a panel that turned
## opaque only while the player carried something passed the whole suite and
## walked the player when clicked at join. That build is a real sabotage, not a
## hypothetical, and it is what this second case exists to catch.
func _test_clicking_the_panel_chrome_reaches_nothing() -> void:
	await _feed(_inventory_frame(WIRE_SIZE, 1))
	await _check_the_chrome_is_a_wall("carrying one item")

	# The state every player is in the moment they join.
	await _feed(_inventory_frame(WIRE_SIZE, 0))
	_check(
		_panel.occupied_slot_count() == 0,
		"the join-state panel is drawn holding nothing, got %d occupied"
		% _panel.occupied_slot_count(),
	)
	await _check_the_chrome_is_a_wall("holding nothing, as at join")


## Clicks the panel's chrome and asserts the click reached nothing.
##
## [b]The counterfactual is asserted, not assumed.[/b] "No `move_to`" is also
## what a click into empty space produces, so the ground under the chrome point
## is resolved with the picker first. The picker answers a ray, not the GUI, so
## it reports what the click [i]would[/i] have hit — and then the click hits the
## panel instead.
func _check_the_chrome_is_a_wall(state: String) -> void:
	# A rebuilt grid has not sorted its children yet, and a widget with no rect
	# is a rect that every point misses. Rendering first also means the filter
	# is judged by what a real click does rather than by reading the property,
	# which is what `_test_the_panel_is_authored` does before any frame runs.
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_panel.visible, "the full-size panel is drawn (%s)" % state)

	var screen := _camera.get_viewport().get_visible_rect()
	var panel_rect := _panel.get_global_rect()
	print("INTERACTION panel rect %s in viewport %s (%s)" % [panel_rect, screen.size, state])

	var chrome: Variant = _panel_chrome_point(panel_rect, screen)
	_check(chrome != null, "the panel draws chrome inside the viewport to click on (%s)" % state)
	if chrome == null:
		return
	var at: Vector2 = chrome
	_check(
		_picker.pick_ground(at) != null,
		"there is ground under %v, so a click that got through would walk the player (%s)"
		% [at, state],
	)

	_watch()
	await _left_click(at)
	_check(
		_move_to_intents.is_empty(),
		"but a click on the panel's chrome at %v sends no move_to (%s), got %s"
		% [at, state, _move_to_intents],
	)
	_check(
		_pickup_intents.is_empty() and _drop_intents.is_empty(),
		"and no pickup and no drop either (%s): chrome is not a control, it is a wall" % state,
	)


## A point inside the panel's drawn rect, inside the viewport, and on no slot
## widget, or null when the panel draws no such point.
##
## Derived rather than written down, because the panel's size comes from the
## theme and the slot metrics. A literal would go stale the first time either
## moved, and it would go stale [i]silently[/i]: a point that had drifted onto a
## slot still sends no `move_to`, so the assertion above it would keep passing
## while testing something else entirely.
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


# --------------------------------------------------------------------------
# The scripted feed.
# --------------------------------------------------------------------------


## `main.gd`'s `--feed` path, driven by an automated test for the first time.
##
## M1c added the flag so a screenshot could show a world with items in it and
## left nothing driving it, which means a regression there surfaces only the
## next time a human opens a PNG. This feeds the very fixture the screenshot is
## captured from and asserts on the frame count and on the world it produced.
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
	var panel := feeder.get_node("UI/InventoryPanel") as InventoryPanelScript
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


# --------------------------------------------------------------------------
# Driving.
# --------------------------------------------------------------------------


## Hands one frame to the client's own decoder and lets it land.
func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


## Forgets every intent seen so far, so the next assertion counts only what the
## next click produced.
func _watch() -> void:
	_move_to_intents.clear()
	_pickup_intents.clear()
	_drop_intents.clear()


## Pushes a real left click at a viewport position and lets it be handled.
func _left_click(screen_position: Vector2) -> void:
	var viewport := _camera.get_viewport()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = screen_position
	viewport.push_input(press)
	await get_tree().process_frame


## Presses and releases the left button over one slot widget. Both halves are
## needed: a [Button] fires on release by default.
func _click_slot(index: int) -> void:
	# A rebuilt grid has not sorted its children yet, and a widget with no rect
	# is a click at (0, 0) that hits nothing.
	await get_tree().process_frame
	await get_tree().process_frame
	var slot := _panel.slot_at(index)
	_check(slot != null, "the panel is drawing slot %d to click" % index)
	if slot == null:
		return
	var viewport := slot.get_viewport()
	var rect := slot.get_global_rect()
	var centre := rect.get_center()
	# A slot that has drifted off the viewport edge still consumes the press and
	# still fires no `pressed`, so it produces no drop and looks exactly like
	# broken wiring (NOTES.md, "Godot authoring traps"). Say which it is.
	_check(
		rect.has_area() and viewport.get_visible_rect().has_point(centre),
		"and slot %d is laid out somewhere clickable (%s in a %s viewport)"
		% [index, rect, viewport.get_visible_rect()],
	)

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = centre
	viewport.push_input(press)

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = centre
	viewport.push_input(release)
	await get_tree().process_frame


## Puts the camera directly above [param ground] looking straight down, so
## screen centre is that point and a click there is unambiguous.
func _look_straight_down_at(ground: Vector2) -> void:
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)),
		Vector3(ground.x, CAMERA_HEIGHT, ground.y),
	)


func _viewport_centre() -> Vector2:
	return _camera.get_viewport().get_visible_rect().size * 0.5


## A cursor offset that is beside the item rather than on it, at whatever size
## this viewport happens to be. See [constant OFFSET_FRACTION].
func _beside_offset() -> Vector2:
	return Vector2(_camera.get_viewport().get_visible_rect().size.y * OFFSET_FRACTION, 0.0)


## An `inventory` frame of [param size] slots with the first [param occupied] of
## them holding an acorn.
static func _inventory_frame(size: int, occupied: int) -> String:
	var slots := PackedStringArray()
	for index in occupied:
		slots.append('{"slot":%d,"kind":"acorn"}' % index)
	return '{"inventory":{"size":%d,"slots":[%s]}}' % [size, ",".join(slots)]


## A `welcome` naming this client as player [constant PLAYER_ID] and no items.
static func _welcome_frame() -> String:
	return (
		'{"welcome":{"you":%d,"tick_ms":150,"tick":900,"players":[{"id":%d,"x":0.0,"z":0.0}],'
		% [PLAYER_ID, PLAYER_ID]
		+ '"items":[]}}'
	)


## True when two colours match channel by channel. `%s` and never `%v` for a
## [Color]: `%v` takes vector types only, fails at runtime, and leaves the
## template unformatted so the failure message degrades to noise (NOTES.md).
func _is_color(actual: Color, expected: Color) -> bool:
	return (
		absf(actual.r - expected.r) <= CHANNEL_EPSILON
		and absf(actual.g - expected.g) <= CHANNEL_EPSILON
		and absf(actual.b - expected.b) <= CHANNEL_EPSILON
	)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
