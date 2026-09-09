extends PanelContainer


const OPTION_ACCEPT := "accept_quest"
const OPTION_TURN_IN := "turn_in_quest"
const OPTION_STOP := "stop_talking"

const ACCEPT_LABEL := "Accept quest"
const TURN_IN_LABEL := "Turn in"

signal option_chosen(npc_id: int, option_id: String)

@export var lines_label: Label
@export var accept_button: Button
@export var stop_button: Button

var _npc_id := 0
var _option_ids := PackedStringArray()
var _primary_option := OPTION_ACCEPT


func _ready() -> void:
	if lines_label == null or accept_button == null or stop_button == null:
		push_error("DialogPanel: the scene did not assign lines_label, accept_button, and stop_button")
		return
	accept_button.pressed.connect(_on_accept_pressed)
	stop_button.pressed.connect(_on_stop_pressed)


func apply(npc_id: int, lines: PackedStringArray, option_ids: PackedStringArray) -> void:
	if lines.is_empty() and option_ids.is_empty():
		clear()
		return
	if npc_id <= 0:
		push_error("DialogPanel.apply: npc ids start at 1, got %d" % npc_id)
		return
	_npc_id = npc_id
	_option_ids = option_ids.duplicate()
	visible = true
	if lines_label != null:
		lines_label.text = "\n".join(lines)
	var can_accept := option_ids.has(OPTION_ACCEPT)
	var can_turn_in := option_ids.has(OPTION_TURN_IN)
	if accept_button != null:
		accept_button.visible = can_accept or can_turn_in
		if can_turn_in:
			accept_button.text = TURN_IN_LABEL
			_primary_option = OPTION_TURN_IN
		else:
			accept_button.text = ACCEPT_LABEL
			_primary_option = OPTION_ACCEPT
	if stop_button != null:
		stop_button.visible = option_ids.has(OPTION_STOP)


func clear() -> void:
	_npc_id = 0
	_option_ids = PackedStringArray()
	_primary_option = OPTION_ACCEPT
	visible = false
	if lines_label != null:
		lines_label.text = ""
	if accept_button != null:
		accept_button.visible = false
		accept_button.text = ACCEPT_LABEL
	if stop_button != null:
		stop_button.visible = false


func npc_id() -> int:
	return _npc_id


func has_option(option_id: String) -> bool:
	return _option_ids.has(option_id)


func _on_accept_pressed() -> void:
	if _npc_id <= 0:
		return
	option_chosen.emit(_npc_id, _primary_option)


func _on_stop_pressed() -> void:
	if _npc_id <= 0:
		return
	option_chosen.emit(_npc_id, OPTION_STOP)