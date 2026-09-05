extends Control

@export var hp_bar: ProgressBar
@export var hp_label: Label
@export var mana_bar: ProgressBar
@export var mana_label: Label

var text: String:
	get:
		return "" if hp_label == null else hp_label.text

var mana_text: String:
	get:
		return "" if mana_label == null else mana_label.text


func apply(hp: int, max_hp: int) -> void:
	if max_hp <= 0:
		push_error("HpHud.apply: max_hp must be positive, got %d" % max_hp)
		return
	_paint_bar(hp_bar, hp_label, hp, max_hp)
	visible = true


func apply_mana(mana: int, max_mana: int) -> void:
	if max_mana <= 0:
		push_error("HpHud.apply_mana: max_mana must be positive, got %d" % max_mana)
		return
	_paint_bar(mana_bar, mana_label, mana, max_mana)
	visible = true


func clear() -> void:
	_paint_bar(hp_bar, hp_label, 0, 100)
	_paint_bar(mana_bar, mana_label, 0, 100)
	if hp_label != null:
		hp_label.text = "—"
	if mana_label != null:
		mana_label.text = "—"
	visible = false


static func _paint_bar(bar: ProgressBar, label: Label, current: int, maximum: int) -> void:
	var capped := clampi(current, 0, maximum)
	if bar != null:
		bar.max_value = maximum
		bar.value = capped
	if label != null:
		label.text = str(capped)
