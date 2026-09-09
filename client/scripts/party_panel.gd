extends PanelContainer


const TOGGLE_ACTION := "toggle_party"

signal invite_pressed()

signal accept_pressed()

signal decline_pressed()

signal leave_pressed()

@export var empty_label: Label
@export var members_label: Label
@export var invite_button: Button
@export var invite_row: Control
@export var invite_label: Label
@export var accept_button: Button
@export var decline_button: Button
@export var leave_button: Button

var _party_id := 0
var _leader_id := 0
var _members := PackedInt32Array()
var _invite_from := 0


func _ready() -> void:
	if (
		empty_label == null
		or members_label == null
		or invite_button == null
		or invite_row == null
		or invite_label == null
		or accept_button == null
		or decline_button == null
		or leave_button == null
	):
		push_error("PartyPanel: the scene did not assign every exported control")
		return
	invite_button.pressed.connect(func() -> void: invite_pressed.emit())
	accept_button.pressed.connect(func() -> void: accept_pressed.emit())
	decline_button.pressed.connect(func() -> void: decline_pressed.emit())
	leave_button.pressed.connect(func() -> void: leave_pressed.emit())
	_redraw()


func toggle() -> void:
	visible = not visible


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed(TOGGLE_ACTION):
		return
	toggle()
	get_viewport().set_input_as_handled()


func apply_party(party_id: int, leader_id: int, members: PackedInt32Array) -> void:
	_party_id = party_id
	_leader_id = leader_id
	_members = members.duplicate()
	_redraw()


func apply_invite(from_player: int) -> void:
	if from_player < 0:
		push_error("PartyPanel.apply_invite: from must be >= 0, got %d" % from_player)
		return
	_invite_from = from_player
	_redraw()


func party_id() -> int:
	return _party_id


func leader_id() -> int:
	return _leader_id


func members() -> PackedInt32Array:
	return _members.duplicate()


func invite_from() -> int:
	return _invite_from


func _redraw() -> void:
	if empty_label == null or members_label == null:
		return

	var in_party := _party_id > 0 and not _members.is_empty()
	empty_label.visible = not in_party
	members_label.visible = in_party
	if in_party:
		var lines := PackedStringArray()
		for member_id in _members:
			if member_id == _leader_id:
				lines.append("%d (leader)" % member_id)
			else:
				lines.append("%d" % member_id)
		members_label.text = "\n".join(lines)
	else:
		members_label.text = ""

	if leave_button != null:
		leave_button.visible = in_party
	if invite_button != null:
		invite_button.visible = true

	var has_invite := _invite_from > 0
	if invite_row != null:
		invite_row.visible = has_invite
	if invite_label != null and has_invite:
		invite_label.text = "Invite from %d" % _invite_from
