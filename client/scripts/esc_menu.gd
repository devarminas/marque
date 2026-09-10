extends Control


signal resume_requested()
signal options_requested()
signal exit_requested()

const KeybindsPanelScript := preload("res://scripts/keybinds_panel.gd")

@export var resume_button: Button
@export var options_button: Button
@export var exit_button: Button
@export var options_panel: Control
@export var options_back_button: Button
@export var keybinds_panel: KeybindsPanelScript


func _ready() -> void:
	if (
		resume_button == null
		or options_button == null
		or exit_button == null
		or options_panel == null
		or options_back_button == null
	):
		push_error(
			"EscMenu: the scene did not assign resume, options, exit, options_panel, and back"
		)
		return
	resume_button.pressed.connect(_on_resume_pressed)
	options_button.pressed.connect(_on_options_pressed)
	exit_button.pressed.connect(_on_exit_pressed)
	options_back_button.pressed.connect(_on_options_back_pressed)
	visible = false
	options_panel.visible = false


func is_open() -> bool:
	return visible


func is_options_open() -> bool:
	return visible and options_panel != null and options_panel.visible


func cancel_keybind_capture() -> bool:
	if keybinds_panel == null or not keybinds_panel.is_capturing():
		return false
	keybinds_panel.cancel_capture()
	return true


func open_menu() -> void:
	visible = true
	if options_panel != null:
		options_panel.visible = false
	if keybinds_panel != null:
		keybinds_panel.cancel_capture()


func close_menu() -> void:
	if keybinds_panel != null:
		keybinds_panel.cancel_capture()
	if options_panel != null:
		options_panel.visible = false
	visible = false


func open_options() -> void:
	if not visible:
		visible = true
	if options_panel != null:
		options_panel.visible = true
	if keybinds_panel != null:
		keybinds_panel.refresh()
	options_requested.emit()


func close_options() -> void:
	if keybinds_panel != null:
		keybinds_panel.cancel_capture()
	if options_panel != null:
		options_panel.visible = false


func _on_resume_pressed() -> void:
	close_menu()
	resume_requested.emit()


func _on_options_pressed() -> void:
	open_options()


func _on_options_back_pressed() -> void:
	close_options()


func _on_exit_pressed() -> void:
	exit_requested.emit()
