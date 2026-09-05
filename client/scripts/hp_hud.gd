extends Control

@export var fill: Control
@export var bar: ProgressBar
@export var label: Label

## Numeric chrome text, for demos/tests that read the HUD without digging children.
var text: String:
	get:
		return "" if label == null else label.text


func apply(hp: int, max_hp: int) -> void:
	if max_hp <= 0:
		push_error("HpHud.apply: max_hp must be positive, got %d" % max_hp)
		return
	if bar != null:
		bar.max_value = max_hp
		bar.value = clampi(hp, 0, max_hp)
	if fill != null:
		var ratio := clampf(float(hp) / float(max_hp), 0.0, 1.0)
		fill.modulate = Color(1.0, ratio, ratio, 1.0)
	if label != null:
		label.text = "HP %d / %d" % [hp, max_hp]
	visible = true


func clear() -> void:
	if bar != null:
		bar.value = 0
	if fill != null:
		fill.modulate = Color(1, 1, 1, 1)
	if label != null:
		label.text = "HP —"
	visible = false
