extends Button


const ItemKinds := preload("res://scripts/item_kinds.gd")

var worn_name := ""

var kind := ""

@export var fill: ColorRect
@export var label: Label
@export var empty_color: Color
@export var known_color: Color
@export var unknown_color: Color

signal equip_from_bag(bag_slot: int)

signal activated(worn: String)


func configure(name: String) -> void:
	if name.is_empty():
		push_error("WornSlot.configure: worn slot names are non-empty strings")
		return
	worn_name = name
	show_empty()


func show_item(item_kind: String) -> void:
	kind = item_kind
	disabled = false
	if not ItemKinds.is_known(item_kind):
		push_warning(
			'WornSlot: %s holds unknown kind "%s"; drawing it magenta' % [worn_name, item_kind]
		)
	_paint(known_color if ItemKinds.is_known(item_kind) else unknown_color, item_kind)


func show_empty() -> void:
	kind = ""
	disabled = true
	_paint(empty_color, worn_name if not worn_name.is_empty() else "?")


func is_occupied() -> bool:
	return not kind.is_empty()


func display_color() -> Color:
	if fill == null:
		return Color(0, 0, 0, 0)
	return fill.color


func _ready() -> void:
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	if is_occupied():
		activated.emit(worn_name)


func _get_drag_data(_at_position: Vector2) -> Variant:
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return typeof(data) == TYPE_DICTIONARY and data.has("bag_slot")


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY or not data.has("bag_slot"):
		return
	equip_from_bag.emit(int(data["bag_slot"]))


func _paint(color: Color, text: String) -> void:
	if fill == null or label == null:
		push_error("WornSlot: the scene did not assign both a fill and a label")
		return
	fill.color = color
	label.text = text
	tooltip_text = "%s: %s" % [worn_name, kind if is_occupied() else "empty"]
