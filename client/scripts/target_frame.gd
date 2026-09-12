extends Control

@export var name_label: Label
@export var hp_bar: ProgressBar
@export var hp_label: Label

var text: String:
	get:
		return "" if hp_label == null else hp_label.text

var name_text: String:
	get:
		return "" if name_label == null else name_label.text


func apply(display_name: String, hp: int, max_hp: int) -> void:
	if max_hp <= 0:
		push_error("TargetFrame.apply: max_hp must be positive, got %d" % max_hp)
		return
	if name_label != null:
		name_label.text = display_name
	var capped := clampi(hp, 0, max_hp)
	if hp_bar != null:
		hp_bar.max_value = max_hp
		hp_bar.value = capped
	if hp_label != null:
		hp_label.text = "%d/%d" % [capped, max_hp]
	visible = true


func clear() -> void:
	if name_label != null:
		name_label.text = ""
	if hp_bar != null:
		hp_bar.max_value = 100
		hp_bar.value = 0
	if hp_label != null:
		hp_label.text = "—"
	visible = false
