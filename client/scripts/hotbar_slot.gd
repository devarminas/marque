extends Button

@export var fill: ColorRect
@export var name_label: Label
@export var key_label: Label
@export var cooling: ColorRect
@export var cooldown_label: Label

const STATE_EMPTY := 0
const STATE_READY := 1
const STATE_COOLING := 2

var ability_id := ""
var state := STATE_EMPTY


func show_ability(id: String, display_name: String, color: Color, key_text: String) -> void:
	ability_id = id
	state = STATE_READY
	disabled = false
	if cooling != null:
		cooling.visible = false
	if cooldown_label != null:
		cooldown_label.visible = false
	if fill != null:
		fill.color = color
	if name_label != null:
		name_label.text = display_name
	if key_label != null:
		key_label.text = key_text


func show_cooldown(remaining: int, total: int, tick_msec: int = 150) -> void:
	if ability_id.is_empty() or total <= 0 or remaining <= 0:
		state = STATE_READY if not ability_id.is_empty() else STATE_EMPTY
		disabled = ability_id.is_empty()
		if cooling != null:
			cooling.visible = false
		if cooldown_label != null:
			cooldown_label.visible = false
		return
	state = STATE_COOLING
	disabled = false
	var fraction := clampf(float(remaining) / float(total), 0.0, 1.0)
	if cooling != null:
		cooling.visible = true
		cooling.anchor_top = 1.0 - fraction
	if cooldown_label != null:
		cooldown_label.text = str(int(ceil(float(remaining * tick_msec) / 1000.0)))
		cooldown_label.visible = true


func show_empty(key_text: String) -> void:
	ability_id = ""
	state = STATE_EMPTY
	disabled = true
	if cooling != null:
		cooling.visible = false
	if cooldown_label != null:
		cooldown_label.visible = false
	if fill != null:
		fill.color = Color(0.16, 0.16, 0.18, 0)
	if name_label != null:
		name_label.text = ""
	if key_label != null:
		key_label.text = key_text
