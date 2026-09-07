extends Control

@export var name_label: Label
@export var hint_label: Label

var text: String:
	get:
		return "" if name_label == null else name_label.text

var hint_text: String:
	get:
		return "" if hint_label == null else hint_label.text


func apply(display_name: String, missing_hint: String) -> void:
	if name_label != null:
		name_label.text = display_name if not display_name.is_empty() else "None"
	if hint_label != null:
		if missing_hint.is_empty():
			hint_label.text = ""
			hint_label.visible = false
		else:
			hint_label.text = missing_hint
			hint_label.visible = true
	visible = true


func clear() -> void:
	if name_label != null:
		name_label.text = "—"
	if hint_label != null:
		hint_label.text = ""
		hint_label.visible = false
	visible = false
