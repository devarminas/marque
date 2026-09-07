extends Control

@export var message_label: Label
@export var linger: Timer

var text: String:
	get:
		return "" if message_label == null else message_label.text


func show_refusal(message: String) -> void:
	if message.is_empty():
		clear()
		return
	if message_label != null:
		message_label.text = message
	visible = true
	if linger != null:
		linger.start()


func clear() -> void:
	if message_label != null:
		message_label.text = ""
	visible = false
	if linger != null:
		linger.stop()
