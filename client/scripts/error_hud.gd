extends Control

@export var message_label: Label
@export var linger: Timer
@export var range_tint := Color(1.0, 0.52, 0.28, 1.0)
@export var mana_tint := Color(0.75, 0.48, 1.0, 1.0)
@export var cooldown_tint := Color(1.0, 0.82, 0.32, 1.0)
@export var default_tint := Color(0.98, 0.74, 0.36, 1.0)

var text: String:
	get:
		return "" if message_label == null else message_label.text


func show_refusal(message: String, reason: String = "") -> void:
	if message.is_empty():
		clear()
		return
	if message_label != null:
		message_label.text = message
		match reason:
			"out_of_range":
				message_label.add_theme_color_override("font_color", range_tint)
			"insufficient_mana":
				message_label.add_theme_color_override("font_color", mana_tint)
			"cooldown":
				message_label.add_theme_color_override("font_color", cooldown_tint)
			_:
				message_label.add_theme_color_override("font_color", default_tint)
	visible = true
	if linger != null:
		linger.start()


func clear() -> void:
	if message_label != null:
		message_label.text = ""
	visible = false
	if linger != null:
		linger.stop()
