extends Control

signal respawn_requested()

@export var respawn_button: Button


func _ready() -> void:
	if respawn_button == null:
		push_error("DeathOverlay: the scene did not assign a respawn button")
		return
	respawn_button.pressed.connect(_on_respawn_pressed)


func _on_respawn_pressed() -> void:
	respawn_requested.emit()
