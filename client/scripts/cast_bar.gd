extends Control

@export var bar: ProgressBar
@export var label: Label


func apply(ability: String, progress: int, total: int) -> void:
	if ability.is_empty() or total <= 0:
		clear()
		return
	if bar != null:
		bar.max_value = total
		bar.value = clampi(progress, 0, total)
	if label != null:
		label.text = ability.capitalize()
	visible = true


func clear() -> void:
	if bar != null:
		bar.value = 0
	if label != null:
		label.text = ""
	visible = false
