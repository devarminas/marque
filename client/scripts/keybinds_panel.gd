extends VBoxContainer


const Keybinds := preload("res://scripts/keybinds.gd")

@export var inventory_button: Button
@export var quest_log_button: Button
@export var status_label: Label

var _listening: StringName = &""


func _ready() -> void:
	if inventory_button == null or quest_log_button == null or status_label == null:
		push_error("KeybindsPanel: scene must assign inventory, quest log, and status")
		return
	inventory_button.pressed.connect(_on_inventory_pressed)
	quest_log_button.pressed.connect(_on_quest_log_pressed)
	visibility_changed.connect(_on_visibility_changed)
	refresh()


func is_capturing() -> bool:
	return _listening != &""


func cancel_capture() -> void:
	_listening = &""
	if status_label != null:
		status_label.text = ""
	refresh()


func refresh() -> void:
	if inventory_button != null:
		inventory_button.text = _button_text("toggle_inventory")
	if quest_log_button != null:
		quest_log_button.text = _button_text("toggle_quest_log")


func _button_text(action: StringName) -> String:
	if _listening == action:
		return "Press a key…"
	return Keybinds.display_name(Keybinds.physical_keycode(action))


func _on_inventory_pressed() -> void:
	_begin_capture(&"toggle_inventory")


func _on_quest_log_pressed() -> void:
	_begin_capture(&"toggle_quest_log")


func _begin_capture(action: StringName) -> void:
	_listening = action
	if status_label != null:
		status_label.text = "Press a key for %s (Esc cancels)." % action
	refresh()


func _on_visibility_changed() -> void:
	if not visible and is_capturing():
		cancel_capture()


func _input(event: InputEvent) -> void:
	if not is_capturing():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_ESCAPE:
		return
	var reason := Keybinds.rebind(_listening, int(key.physical_keycode))
	_listening = &""
	if status_label != null:
		status_label.text = reason
	refresh()
	get_viewport().set_input_as_handled()
