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

@export var hover_popup: PanelContainer

@export var hover_image: ColorRect

@export var hover_name: Label

@export var hover_class: Label

var _pointer_inside := false


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
	_sync_hover()


func show_empty() -> void:
	kind = ""
	disabled = true
	_paint(empty_color, str(slot_index))
	_sync_hover()


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


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		_on_mouse_entered()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_on_mouse_exited()


func _on_mouse_entered() -> void:
	_pointer_inside = true
	_sync_hover()


func _on_mouse_exited() -> void:
	_pointer_inside = false
	_sync_hover()


func _paint(color: Color, text: String) -> void:
	if fill == null or label == null:
		push_error("InventorySlot: the scene did not assign both a fill and a label")
		return
	fill.color = color
	label.text = text


func _sync_hover() -> void:
	if _pointer_inside and is_occupied():
		_enter_shown()
	else:
		_enter_hidden()


func _enter_shown() -> void:
	if not _hover_nodes_ok():
		return
	hover_image.color = display_color()
	hover_name.text = ItemKinds.display_name(kind)
	hover_class.text = ItemKinds.item_class(kind)
	hover_popup.visible = true
	_place_hover_popup()


func _enter_hidden() -> void:
	if not _hover_nodes_ok():
		return
	hover_popup.visible = false


func _place_hover_popup() -> void:
	var popup_size := hover_popup.get_combined_minimum_size()
	if popup_size.x < 1.0:
		popup_size = hover_popup.size
	if popup_size.x < 1.0:
		popup_size = hover_popup.custom_minimum_size
	hover_popup.global_position = Vector2(
		global_position.x - popup_size.x - 4.0,
		global_position.y
	)


func _hover_nodes_ok() -> bool:
	if hover_popup == null or hover_image == null or hover_name == null or hover_class == null:
		push_error("InventorySlot: the scene did not assign hover popup, image, name, and class")
		return false
	return true
