extends Button

@export var fill: ColorRect
@export var name_label: Label
@export var key_label: Label

var ability_id := ""


func show_ability(id: String, display_name: String, color: Color, key_text: String) -> void:
	ability_id = id
	disabled = false
	if fill != null:
		fill.color = color
	if name_label != null:
		name_label.text = display_name
	if key_label != null:
		key_label.text = key_text


func show_empty(key_text: String) -> void:
	ability_id = ""
	disabled = true
	if fill != null:
		fill.color = Color(0.16, 0.16, 0.18, 0)
	if name_label != null:
		name_label.text = ""
	if key_label != null:
		key_label.text = key_text
