extends Node3D

## The equipment panel: authored, opened, closed, and opaque. **M3b.**
##
## [b]No server.[/b] Nothing here needs one. The panel is player-driven chrome,
## so every assertion is either about `main.tscn` as authored or about what a
## real [InputEventKey] and a real [InputEventMouseButton] pushed through a real
## viewport do to it.
##
## The thing under test is `main.tscn` itself, so this is about the scene the
## game ships rather than a rig assembled for the occasion.
##
## [b]The opacity claim is written as its own negative.[/b] "A click on the open
## panel sends no `move_to`" is also what a click into empty sky produces, and
## it is what a panel that is simply never drawn produces. So the ground under
## the click point is resolved with the picker first, and then the same click at
## the same point is pushed again with the panel closed and asserted to walk the
## player. Either half alone passes for a build that is broken the other way.

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const InventorySlotScene := preload("res://scenes/inventory_slot.tscn")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const Assertions := preload("res://tests/assertions.gd")

## The action `project.godot` authors, and the physical key it is bound to.
## Physical, so the bind survives a non-QWERTY layout.
const TOGGLE_ACTION := "toggle_equipment"
const TOGGLE_KEY := KEY_E

## How far the panel sits from the two edges it is anchored to, matching the
## inventory panel's inset on the opposite corner.
const EDGE_INSET := 16.0

## Camera height for the click tests. High enough that the whole viewport is
## ground, so a click that gets through lands on the ground rather than the sky.
const CAMERA_HEIGHT := 20.0

## Tolerance for a laid-out edge, in pixels.
const LAYOUT_EPSILON := 0.5

## Scripts that must never assign `mouse_filter`. Scanned as source, because the
## property being right when a test looks at it is a weaker claim than nothing
## in the client being able to change it.
const SCRIPTS_DIR := "res://scripts"

## Everything the panel draws inside itself. All of it authored, and none of it
## allowed to catch a click.
const CHROME_PATHS := [
	"Margin",
	"Margin/Rows",
	"Margin/Rows/Heading",
	"Margin/Rows/WeaponSlot",
]

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _picker: GroundPickerScript = null
var _camera: Camera3D = null
var _panel: EquipmentPanelScript = null
var _inventory: InventoryPanelScript = null

var _move_to_intents := PackedVector2Array()

## Where the opacity pair clicks. Derived once, by the open-panel test, so that
## the closed-panel test can make the stronger claim: not a click at the same
## computation, the same click.
var _click_point := Vector2.INF


## Suite contract, polled by `run_tests.gd`. Reports; never quits.
func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== equipment: a panel the player opens, no server ==")
	# Asserted against an instance that is not in the tree yet, so no `_ready`
	# anywhere has run. See the method's own note.
	_test_the_panel_is_authored_before_anything_runs()

	_root = MainScene.instantiate() as Node3D
	_root.name = "EquipmentClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_picker = _root.get_node("GroundPicker") as GroundPickerScript
	_camera = _root.get_node("CameraRig/Camera3D") as Camera3D
	_panel = _root.get_node("UI/EquipmentPanel") as EquipmentPanelScript
	_inventory = _root.get_node("UI/InventoryPanel") as InventoryPanelScript

	# The rig chases its target every frame and would undo the camera placement
	# the click tests depend on. Switched off rather than fought.
	var rig := _root.get_node("CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	_session.move_to_requested.connect(func(x: float, z: float) -> void:
		_move_to_intents.append(Vector2(x, z))
	)

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


# --------------------------------------------------------------------------
# Authoring.
# --------------------------------------------------------------------------


## [b]AC3 and AC4, at the only moment that can tell authoring from
## construction.[/b] The instance is not in the tree, so no `_ready` has run
## anywhere in it. Every property asserted here therefore came out of
## `main.tscn` and could not have been assigned by a script.
##
## This is the assertion CLAUDE.md's scene-authoring rule actually needs. A
## panel built by an `add_child` in `_ready` passes every other test in this
## file and fails only this one.
func _test_the_panel_is_authored_before_anything_runs() -> void:
	var unopened := MainScene.instantiate() as Node3D
	var panel := unopened.get_node_or_null("UI/EquipmentPanel") as Control
	_check(panel != null, "main.tscn authors UI/EquipmentPanel, before any _ready runs")
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
		panel.anchor_left == 0.0 and panel.anchor_right == 0.0,
		"and anchors it to the left edge, got left %f right %f"
		% [panel.anchor_left, panel.anchor_right],
	)

	# The chrome is authored too, and exactly one node in the panel stops a
	# click. A container that stopped as well would work today and would move
	# the boundary the next time the tree changed shape.
	for path: String in CHROME_PATHS:
		var chrome := panel.get_node_or_null(path) as Control
		_check(chrome != null, "and authors %s inside it" % path)
		_check(
			chrome != null and chrome.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"which hands a missed click down to the panel rather than catching it (%s)" % path,
		)

	unopened.queue_free()


## [b]AC4.[/b] The panel is one of the UI layer's children, alongside the
## inventory panel, and the two are anchored to opposite sides.
func _test_the_panel_hangs_off_the_ui_layer() -> void:
	var layer := _panel.get_parent()
	_check(layer != null and layer.name == "UI", "the panel hangs off UI/")
	_check(layer is CanvasLayer, "which is a CanvasLayer, so it draws over the world")
	_check(
		_inventory != null and _inventory.get_parent() == layer,
		"the same layer the inventory panel hangs off",
	)
	_check(
		_inventory.anchor_left == 1.0 and _panel.anchor_left == 0.0,
		"and the inventory is anchored right while equipment is anchored left",
	)


## [b]AC3, the durable half.[/b] `mouse_filter` is authored, and no client
## script can assign it. Read out of the source rather than off the property:
## the property being right at the moment a test looks is exactly what M1k's
## regression looked like too.
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


## One worn slot, drawn and empty. What is worn arrives on the wire in a later
## unit, so "empty" is the whole of M3b's claim about its contents.
##
## The empty colour is read off `inventory_slot.tscn` rather than written down
## here, so "a worn slot looks like an empty slot" cannot quietly decay into "a
## worn slot is whatever shade this test was written with".
func _test_the_worn_weapon_slot_is_drawn_empty() -> void:
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	var slot := _panel.get_node_or_null("Margin/Rows/WeaponSlot") as ColorRect
	_check(slot != null, "the panel draws a worn weapon slot")
	if slot == null:
		return
	_check(
		slot.get_global_rect().has_area(),
		"which is laid out with an area, got %s" % [slot.get_global_rect()],
	)

	var reference := InventorySlotScene.instantiate() as InventorySlotScript
	_check(
		slot.color == reference.empty_color,
		"and drawn the very shade inventory_slot.tscn authors for an empty slot, %s, got %s"
		% [reference.empty_color, slot.color],
	)
	reference.queue_free()

	var label := slot.get_node_or_null("Label") as Label
	_check(label != null and label.text == "weapon", "and named for the slot it is")
	_panel.visible = false


# --------------------------------------------------------------------------
# Opening and closing.
# --------------------------------------------------------------------------


## [b]AC1.[/b]
func _test_the_toggle_flips_visibility() -> void:
	_check(not _panel.visible, "the panel starts closed")
	_panel.toggle()
	_check(_panel.visible, "one toggle opens it")
	_panel.toggle()
	_check(not _panel.visible, "and the next closes it again")


## The bind is configuration, not a keycode in a script, so it is asserted
## against the [InputMap] the project file built.
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
		"and binds it to the physical E key, so it stays put on a non-QWERTY layout",
	)


## [b]AC1, through the path a player actually uses.[/b] A real key event pushed
## through a real viewport, at a panel that is hidden when the event arrives: a
## hidden node still receives `_unhandled_key_input`, and this is the assertion
## that says so out loud.
func _test_the_authored_key_opens_and_closes_it() -> void:
	_check(not _panel.visible, "the panel is closed before the key is pressed")

	await _push_toggle_key()
	_check(_panel.visible, "pressing the authored key opens the panel")

	await _push_toggle_key()
	_check(not _panel.visible, "and pressing it again closes it")


## The panel is drawn against the left edge, measured on a live frame rather
## than read off the anchors. The inset matches the inventory panel's on the
## opposite corner.
##
## [b]The bottom edge is load-bearing and not decoration.[/b] The headless
## viewport is 64x64 (NOTES.md), where this panel is far wider than the whole
## screen, so an equipment panel anchored anywhere but the bottom would cover
## `test_wiring.gd`'s `CLICK_AT` and leave the suite with no world to click.
## Anchored to the bottom-left with this inset, its bottom edge lands exactly on
## the 16px strip that constant already aims at. `test_wiring.gd` guards the
## constant; this guards the edge that makes it reachable.
func _test_the_panel_is_left_anchored_where_it_is_drawn() -> void:
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	var screen := _camera.get_viewport().get_visible_rect()
	var rect := _panel.get_global_rect()
	print("EQUIPMENT panel rect %s in viewport %s" % [rect, screen.size])

	_check(rect.has_area(), "the open panel is laid out with an area, got %s" % [rect])
	_check(
		absf(rect.position.x - EDGE_INSET) < LAYOUT_EPSILON,
		"its left edge sits %f px from the left edge, expected %f"
		% [rect.position.x, EDGE_INSET],
	)
	_check(
		absf(rect.end.y - (screen.size.y - EDGE_INSET)) < LAYOUT_EPSILON,
		"and its bottom edge sits %f px from the bottom, expected %f"
		% [screen.size.y - rect.end.y, EDGE_INSET],
	)
	_panel.visible = false


# --------------------------------------------------------------------------
# Opacity.
# --------------------------------------------------------------------------


## [b]AC2.[/b] A click inside the open panel's rect sends no `move_to`.
##
## The inventory panel is asserted closed first. It is anchored to the opposite
## corner and covers most of a 64x64 viewport when it is open, so an open one
## would be free to swallow this click and let a transparent equipment panel
## pass this test.
func _test_an_open_panel_swallows_a_click() -> void:
	_check(
		not _inventory.visible,
		"the inventory panel is closed, so nothing else can be what stops this click",
	)

	_look_straight_down()
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	_click_point = _point_inside_the_panel()
	_check(
		_click_point != Vector2.INF,
		"the open panel covers a point inside the viewport to click",
	)
	if _click_point == Vector2.INF:
		return
	_check(
		_picker.pick_ground(_click_point) != null,
		"there is ground under %v, so a click that got through would walk the player"
		% _click_point,
	)

	_move_to_intents.clear()
	await _push_left_click(_click_point)
	_check(
		_move_to_intents.is_empty(),
		"but a click on the open panel at %v sends no move_to, got %s"
		% [_click_point, _move_to_intents],
	)


## The counterfactual for the test above, at the same point, with the same
## click. Without this, a panel that was never drawn at all would pass.
func _test_a_closed_panel_lets_the_same_click_through() -> void:
	if _click_point == Vector2.INF:
		return
	_panel.visible = false
	await get_tree().process_frame
	await get_tree().process_frame

	_move_to_intents.clear()
	await _push_left_click(_click_point)
	_check(
		_move_to_intents.size() == 1,
		"with the panel closed the very same click at %v walks the player, got %d intent(s)"
		% [_click_point, _move_to_intents.size()],
	)


## [b]AC3, behaviourally.[/b] Nothing in the open/close path touches the filter,
## so it is still STOP after the panel has been round the loop several times.
func _test_toggling_never_re_arms_the_filter() -> void:
	for _round in 3:
		_panel.toggle()
		await get_tree().process_frame
		_check(
			_panel.mouse_filter == Control.MOUSE_FILTER_STOP,
			"the filter is still STOP with the panel %s, got %d"
			% ["open" if _panel.visible else "closed", _panel.mouse_filter],
		)


# --------------------------------------------------------------------------
# Driving.
# --------------------------------------------------------------------------


## A point inside the open panel's rect and inside the viewport, or
## [constant Vector2.INF] when the panel covers no such point.
##
## Derived rather than written down: the panel's size comes from the theme and
## the slot metrics, and a literal would go stale silently the first time either
## moved, because a point that had drifted off the panel still sends no
## `move_to` when the click lands on empty sky.
func _point_inside_the_panel() -> Vector2:
	var screen := _camera.get_viewport().get_visible_rect()
	var covered := _panel.get_global_rect().intersection(screen)
	if not covered.has_area():
		return Vector2.INF
	return covered.get_center()


## Presses and releases the authored key. Both halves, so a press cannot leave
## the action latched for the next assertion.
func _push_toggle_key() -> void:
	var viewport := _camera.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = TOGGLE_KEY
		event.pressed = pressed
		viewport.push_input(event)
	await get_tree().process_frame


## Presses and releases the left button. Both, so a press landing on the panel
## cannot leave it holding mouse focus for the next click.
func _push_left_click(screen_position: Vector2) -> void:
	var viewport := _camera.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = screen_position
		viewport.push_input(event)
	await get_tree().process_frame


## Puts the camera above the origin looking straight down, so every point in the
## viewport is ground and a click that gets through has somewhere to land.
func _look_straight_down() -> void:
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)),
		Vector3(0.0, CAMERA_HEIGHT, 0.0),
	)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
