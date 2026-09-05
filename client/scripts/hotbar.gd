extends Control

const AbilityDefs := preload("res://scripts/ability_defs.gd")
const HotbarSlotScript := preload("res://scripts/hotbar_slot.gd")

const HOTBAR_1 := "hotbar_1"
const HOTBAR_2 := "hotbar_2"

signal ability_activated(ability_id: String)

@export var slot_1: HotbarSlotScript
@export var slot_2: HotbarSlotScript

var _catalog: Dictionary = AbilityDefs._empty_catalog()
var _slot_ability := {}


func _ready() -> void:
	if slot_1 != null:
		slot_1.pressed.connect(func() -> void: _activate_slot(1))
	if slot_2 != null:
		slot_2.pressed.connect(func() -> void: _activate_slot(2))
	reload_from_json()


func reload_from_json() -> void:
	_catalog = AbilityDefs.load_default()
	_slot_ability.clear()
	for id in AbilityDefs.ids(_catalog):
		var ability: Variant = AbilityDefs.get_ability(_catalog, id)
		if typeof(ability) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = ability
		var ui: Variant = row.get("ui", {})
		if typeof(ui) != TYPE_DICTIONARY:
			continue
		var slot_n := int(ui.get("hotbar_slot", 0))
		if slot_n == 1 or slot_n == 2:
			_slot_ability[slot_n] = row
	_paint_slot(1, slot_1, "1")
	_paint_slot(2, slot_2, "2")


func ability_id_in_slot(slot_n: int) -> String:
	var row: Variant = _slot_ability.get(slot_n, null)
	if typeof(row) != TYPE_DICTIONARY:
		return ""
	return String(row.get("id", ""))


func catalog() -> Dictionary:
	return _catalog


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed(HOTBAR_1):
		_activate_slot(1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(HOTBAR_2):
		_activate_slot(2)
		get_viewport().set_input_as_handled()


## Slots are authored mouse-filter ignore so a 64x64 headless viewport can still
## ground-click through the bar. Desktop clicks are hit-tested here instead.
func _input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	if button.button_index != MOUSE_BUTTON_LEFT:
		return
	var viewport := get_viewport()
	if viewport == null or viewport.get_visible_rect().size.x < 200.0:
		return
	if _hit_slot(slot_1, button.position):
		_activate_slot(1)
		viewport.set_input_as_handled()
		return
	if _hit_slot(slot_2, button.position):
		_activate_slot(2)
		viewport.set_input_as_handled()


func _hit_slot(widget: HotbarSlotScript, screen_position: Vector2) -> bool:
	return widget != null and widget.get_global_rect().has_point(screen_position)


func _activate_slot(slot_n: int) -> void:
	var id := ability_id_in_slot(slot_n)
	if id.is_empty():
		return
	ability_activated.emit(id)


func _paint_slot(slot_n: int, widget: HotbarSlotScript, key_text: String) -> void:
	if widget == null:
		return
	var row: Variant = _slot_ability.get(slot_n, null)
	if typeof(row) != TYPE_DICTIONARY:
		widget.show_empty(key_text)
		return
	var ability: Dictionary = row
	var ui: Dictionary = ability.get("ui", {})
	widget.show_ability(
		String(ability.get("id", "")),
		String(ability.get("name", "")),
		_color_for(String(ui.get("color", ""))),
		key_text,
	)


func _color_for(name: String) -> Color:
	match name:
		"green":
			return Color(0.22, 0.72, 0.32, 1)
		"red":
			return Color(0.82, 0.2, 0.16, 1)
		_:
			return Color(0.45, 0.45, 0.5, 1)
