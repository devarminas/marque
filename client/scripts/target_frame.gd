extends Control

const CastBarScript := preload("res://scripts/cast_bar.gd")

@export var name_label: Label
@export var hp_bar: ProgressBar
@export var hp_label: Label
@export var cast_bar: CastBarScript

var text: String:
	get:
		return "" if hp_label == null else hp_label.text

var name_text: String:
	get:
		return "" if name_label == null else name_label.text

var cast_text: String:
	get:
		if cast_bar == null or cast_bar.label == null:
			return ""
		return cast_bar.label.text

var cast_visible: bool:
	get:
		return cast_bar != null and cast_bar.visible


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


func apply_cast(ability: String, progress: int, total: int) -> void:
	if cast_bar == null:
		return
	cast_bar.apply(ability, progress, total)


func clear_cast() -> void:
	if cast_bar != null:
		cast_bar.clear()


func clear() -> void:
	if name_label != null:
		name_label.text = ""
	if hp_bar != null:
		hp_bar.max_value = 100
		hp_bar.value = 0
	if hp_label != null:
		hp_label.text = "—"
	clear_cast()
	visible = false
