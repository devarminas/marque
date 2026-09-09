extends PanelContainer


const OPTION_ACCEPT := "accept_quest"
const OPTION_STOP := "stop_talking"

signal option_chosen(npc_id: int, option_id: String)

@export var lines_label: Label
@export var accept_button: Button
@export var stop_button: Button

var _npc_id := 0


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
	visible = true
	if lines_label != null:
		lines_label.text = "\n".join(lines)
	if accept_button != null:
		accept_button.visible = option_ids.has(OPTION_ACCEPT)
	if stop_button != null:
		stop_button.visible = option_ids.has(OPTION_STOP)


func clear() -> void:
	_npc_id = 0
	visible = false
	if lines_label != null:
		lines_label.text = ""
	if accept_button != null:
		accept_button.visible = false
	if stop_button != null:
		stop_button.visible = false


func npc_id() -> int:
	return _npc_id


func _on_accept_pressed() -> void:
	if _npc_id <= 0:
		return
	option_chosen.emit(_npc_id, OPTION_ACCEPT)


func _on_stop_pressed() -> void:
	if _npc_id <= 0:
		return
	option_chosen.emit(_npc_id, OPTION_STOP)
