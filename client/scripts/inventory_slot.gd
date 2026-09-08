extends Button


const ItemKinds := preload("res://scripts/item_kinds.gd")

signal equip_requested(slot: int)

signal drop_requested(slot: int)

var slot_index := -1

var kind := ""

@export var fill: ColorRect

@export var label: Label

@export var empty_color: Color

@export var known_color: Color

@export var unknown_color: Color


func configure(index: int) -> void:
	if index < 0:
		push_error("InventorySlot.configure: slot indices start at 0, got %d" % index)
		return
	slot_index = index
	show_empty()


func show_item(item_kind: String) -> void:
	kind = item_kind
	disabled = false
	if not ItemKinds.is_known(item_kind):
		push_warning(
			'InventorySlot: slot %d holds unknown kind "%s"; drawing it magenta'
			% [slot_index, item_kind]
		)
	_paint(known_color if ItemKinds.is_known(item_kind) else unknown_color, item_kind)


func show_empty() -> void:
	kind = ""
	disabled = true
	_paint(empty_color, str(slot_index))


func is_occupied() -> bool:
	return not kind.is_empty()


func display_color() -> Color:
	if fill == null:
		return Color(0, 0, 0, 0)
	return fill.color


func _gui_input(event: InputEvent) -> void:
	if not is_occupied():
		return
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	if button.button_index == MOUSE_BUTTON_RIGHT:
		equip_requested.emit(slot_index)
		accept_event()
		return
	if button.button_index == MOUSE_BUTTON_LEFT and button.shift_pressed:
		drop_requested.emit(slot_index)
		accept_event()


func _get_drag_data(_at_position: Vector2) -> Variant:
	if not is_occupied():
		return null
	var preview := Label.new()
	preview.text = kind
	set_drag_preview(preview)
	return {"bag_slot": slot_index}


func _paint(color: Color, text: String) -> void:
	if fill == null or label == null:
		push_error("InventorySlot: the scene did not assign both a fill and a label")
		return
	fill.color = color
	label.text = text
	tooltip_text = "slot %d: %s" % [slot_index, kind if is_occupied() else "empty"]
