extends Control

const ClassDefs := preload("res://scripts/class_defs.gd")

@export var debug_label: Label

var text: String:
	get:
		return "" if debug_label == null else debug_label.text


func apply(formatted: String) -> void:
	if debug_label != null:
		debug_label.text = formatted
	visible = true


func clear() -> void:
	if debug_label != null:
		debug_label.text = "None"
	visible = true


static func format(
	class_id: String, classes: Dictionary, skill_levels: Dictionary
) -> String:
	if class_id.is_empty():
		return "None"
	var entry: Variant = ClassDefs.lookup_class(classes, class_id)
	if entry == null:
		return "None"
	var skill_id := String(entry["skill"])
	var level := int(skill_levels.get(skill_id, 1))
	var display := ClassDefs.class_display_name(classes, class_id)
	return "%s Lv %d (%s)" % [display, level, skill_id]
