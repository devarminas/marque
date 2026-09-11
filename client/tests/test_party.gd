extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PartyPanelScript := preload("res://scripts/party_panel.gd")
const Assertions := preload("res://tests/assertions.gd")

const TOGGLE_ACTION := "toggle_party"
const TOGGLE_KEY := KEY_P
const CAMERA_HEIGHT := 20.0
const CLICK_ITEM_ID := 5
const SELECTED_PLAYER_ID := 3
const SCRIPTS_DIR := "res://scripts"

const CHROME_PATHS := [
	"Margin",
	"Margin/Rows",
	"Margin/Rows/Heading",
	"Margin/Rows/Empty",
	"Margin/Rows/Members",
	"Margin/Rows/InviteRow",
	"Margin/Rows/InviteRow/Notice",
]

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _camera: Camera3D = null
var _panel: PartyPanelScript = null

var _pickup_intents := PackedInt32Array()
var _invite_intents := PackedInt32Array()
var _accept_count := 0
var _decline_count := 0
var _leave_count := 0
var _click_point := Vector2.INF


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== party: roster panel reflects restatement; intents only ==")
	_test_the_panel_is_authored_before_anything_runs()

	_root = MainScene.instantiate() as Node3D
	_root.name = "PartyClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_picker = _root.get_node("GroundPicker") as GroundPickerScript
	_camera = _root.get_node("PlayerCharacter/CameraRig/Camera3D") as Camera3D
	_panel = _root.get_node("UI/PartyPanel") as PartyPanelScript

	var rig := _root.get_node("PlayerCharacter/CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)

	_session.pickup_requested.connect(func(id: int) -> void: _pickup_intents.append(id))
	_session.party_invite_requested.connect(func(id: int) -> void: _invite_intents.append(id))
	_session.party_accept_requested.connect(func() -> void: _accept_count += 1)
	_session.party_decline_requested.connect(func() -> void: _decline_count += 1)
	_session.party_leave_requested.connect(func() -> void: _leave_count += 1)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	_test_the_panel_hangs_off_the_ui_layer()
	_test_no_client_script_assigns_a_mouse_filter()
	_test_the_toggle_flips_visibility()
	_test_the_keybind_is_authored()
	await _test_the_authored_key_opens_and_closes_it()
	await _test_restatement_and_invite_prompt()
	await _test_invite_accept_leave_intents()
	await _test_an_open_panel_swallows_a_click()
	await _test_a_closed_panel_lets_the_same_click_through()

	print(
		"PARTY RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_panel_is_authored_before_anything_runs() -> void:
	var unopened := MainScene.instantiate() as Node3D
	var panel := unopened.get_node_or_null("UI/PartyPanel") as Control
	_check(panel != null, "main.tscn authors UI/PartyPanel before any _ready runs")
	if panel == null:
		unopened.queue_free()
		return
	_check(panel.get_script() == PartyPanelScript, "and it runs party_panel.gd")
	_check(not panel.visible, "and the scene file starts it closed")
	_check(
		panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and the scene file makes it opaque, got filter %d" % panel.mouse_filter,
	)
	var toggle := unopened.get_node_or_null("UI/PartyToggle") as Button
	_check(toggle != null, "and authors UI/PartyToggle beside the dock")
	_check(
		toggle != null and toggle.mouse_filter == Control.MOUSE_FILTER_STOP,
		"with STOP so the closed panel still offers a clickable P",
	)
	for path: String in CHROME_PATHS:
		var chrome := panel.get_node_or_null(path) as Control
		_check(chrome != null, "and authors %s inside it" % path)
		_check(
			chrome != null and chrome.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"which hands a missed click down to the panel (%s)" % path,
		)
	unopened.queue_free()


func _test_the_panel_hangs_off_the_ui_layer() -> void:
	var layer := _panel.get_parent()
	_check(layer != null and layer.name == "UI", "the party panel hangs off UI/")
	_check(layer is CanvasLayer, "which is a CanvasLayer")


func _test_no_client_script_assigns_a_mouse_filter() -> void:
	var assignment := RegEx.new()
	assignment.compile("mouse_filter\\s*=(?!=)")
	var source := FileAccess.get_file_as_string("%s/party_panel.gd" % SCRIPTS_DIR)
	_check(
		assignment.search(source) == null,
		"party_panel.gd never assigns mouse_filter; the scene owns click stop",
	)


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
		"and binds it to the physical P key",
	)


func _test_the_authored_key_opens_and_closes_it() -> void:
	_check(not _panel.visible, "the panel is closed before the key is pressed")
	await _push_toggle_key()
	_check(_panel.visible, "pressing the authored key opens the panel")
	await _push_toggle_key()
	_check(not _panel.visible, "and pressing it again closes it")


func _test_restatement_and_invite_prompt() -> void:
	_panel.visible = true
	_net.ingest_text_frame('{"party":{"id":0,"leader":0,"members":[]}}')
	await get_tree().process_frame
	var empty := _panel.get_node("Margin/Rows/Empty") as Label
	var members := _panel.get_node("Margin/Rows/Members") as Label
	_check(empty != null and empty.visible, "empty party shows the empty state")
	_check(
		empty != null and empty.text == "Not in a party.",
		"empty state text is the authored chrome, got %s" % (empty.text if empty else ""),
	)
	_check(members != null and not members.visible, "and hides the members label")

	_net.ingest_text_frame('{"party_invite_notice":{"from":2}}')
	await get_tree().process_frame
	var invite_row := _panel.get_node("Margin/Rows/InviteRow") as Control
	_check(invite_row != null and invite_row.visible, "an invite notice shows accept/decline")
	var notice := _panel.get_node("Margin/Rows/InviteRow/Notice") as Label
	_check(
		notice != null and notice.text.contains("2"),
		"and names the inviter, got %s" % (notice.text if notice else ""),
	)

	_net.ingest_text_frame('{"party":{"id":1,"leader":2,"members":[2,3]}}')
	await get_tree().process_frame
	_check(empty != null and not empty.visible, "a membership restatement hides empty")
	_check(members != null and members.visible, "and shows members")
	_check(
		members != null and members.text.contains("2 (leader)"),
		"and marks the leader, got %s" % (members.text if members else ""),
	)
	_check(
		members != null and members.text.contains("3"),
		"and lists the other member",
	)
	var leave := _panel.get_node("Margin/Rows/Leave") as Button
	_check(leave != null and leave.visible, "and offers leave while in a party")
	_check(_panel.visible, "a restatement never closes the player-toggled panel")
	_panel.visible = false


func _test_invite_accept_leave_intents() -> void:
	_panel.visible = true
	_invite_intents.clear()
	_accept_count = 0
	_decline_count = 0
	_leave_count = 0

	_net.ingest_text_frame(
		(
			'{"welcome":{"you":1,"tick_ms":150,"tick":900,'
			+ '"players":[{"id":1,"x":0.0,"z":0.0},{"id":%d,"x":2.0,"z":0.0}]}}'
		)
		% SELECTED_PLAYER_ID
	)
	await get_tree().process_frame
	_check(
		_session.select_player(SELECTED_PLAYER_ID),
		"selection is player %d before invite" % SELECTED_PLAYER_ID,
	)
	_check(
		_session.selected_player_id() == SELECTED_PLAYER_ID,
		"session caches the selected player id",
	)
	(_panel.get_node("Margin/Rows/Invite") as Button).pressed.emit()
	_check(
		_invite_intents.size() == 1 and _invite_intents[0] == SELECTED_PLAYER_ID,
		"Invite selected emits party_invite for the selection, got %s" % [_invite_intents],
	)

	_net.ingest_text_frame('{"party_invite_notice":{"from":2}}')
	await get_tree().process_frame
	(_panel.get_node("Margin/Rows/InviteRow/Accept") as Button).pressed.emit()
	_check(_accept_count == 1, "Accept emits party_accept, got %d" % _accept_count)

	_net.ingest_text_frame('{"party_invite_notice":{"from":0}}')
	_net.ingest_text_frame('{"party":{"id":1,"leader":2,"members":[2,%d]}}' % SELECTED_PLAYER_ID)
	await get_tree().process_frame
	(_panel.get_node("Margin/Rows/Leave") as Button).pressed.emit()
	_check(_leave_count == 1, "Leave emits party_leave, got %d" % _leave_count)

	_net.ingest_text_frame('{"party_invite_notice":{"from":4}}')
	await get_tree().process_frame
	(_panel.get_node("Margin/Rows/InviteRow/Decline") as Button).pressed.emit()
	_check(_decline_count == 1, "Decline emits party_decline, got %d" % _decline_count)

	_net.ingest_text_frame('{"party_invite_notice":{"from":0}}')
	_net.ingest_text_frame('{"party":{"id":0,"leader":0,"members":[]}}')
	await get_tree().process_frame
	_check(_panel.party_id() == 0, "empty restatement clears cached party id")
	_check(_panel.invite_from() == 0, "cleared invite notice hides the prompt")
	_panel.visible = false

func _test_an_open_panel_swallows_a_click() -> void:
	_look_straight_down()
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	_click_point = _point_inside_the_panel()
	_check(
		_click_point != Vector2.INF,
		"the open party panel covers a point inside the viewport to click (rect %s screen %s)"
		% [_panel.get_global_rect(), _camera.get_viewport().get_visible_rect()],
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
		"but a click on the open party panel at %v sends no pickup, got %s"
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


func _look_straight_down() -> void:
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)),
		Vector3(0.0, CAMERA_HEIGHT, 0.0),
	)


func _point_inside_the_panel() -> Vector2:
	var screen := _camera.get_viewport().get_visible_rect()
	var covered := _panel.get_global_rect().intersection(screen)
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


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
