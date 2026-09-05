extends PanelContainer

## Right dock: authored worn cross above nested inventory. I toggles visibility.

const WornSlotScript := preload("res://scripts/worn_slot.gd")

const TOGGLE_ACTION := "toggle_inventory"

## Emitted when the player activates an occupied worn slot (`unequip`).
signal worn_activated(worn: String)

## Emitted when a bag slot is dropped onto a worn slot (`equip`).
signal equip_from_bag(bag_slot: int)

@export var helmet_slot: WornSlotScript
@export var left_hand_slot: WornSlotScript
@export var chest_slot: WornSlotScript
@export var right_hand_slot: WornSlotScript
@export var trousers_slot: WornSlotScript

var _slots := {}


func _ready() -> void:
	_bind_authored(helmet_slot, "helmet")
	_bind_authored(left_hand_slot, "left hand")
	_bind_authored(chest_slot, "chest")
	_bind_authored(right_hand_slot, "right hand")
	_bind_authored(trousers_slot, "trousers")


func toggle() -> void:
	visible = not visible


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed(TOGGLE_ACTION):
		return
	toggle()
	get_viewport().set_input_as_handled()


## Applies one `equipment` frame, wholesale. Never grows worn widgets.
func apply(
	worn_names: PackedStringArray,
	slot_names: PackedStringArray,
	slot_kinds: PackedStringArray,
) -> void:
	if slot_names.size() != slot_kinds.size():
		push_error(
			"EquipmentPanel.apply: %d slot name(s) against %d kind(s)"
			% [slot_names.size(), slot_kinds.size()]
		)
		return

	for name: String in worn_names:
		if not _slots.has(name):
			push_error('EquipmentPanel.apply: unknown worn name "%s"' % name)

	for slot: WornSlotScript in _slots.values():
		slot.show_empty()

	for entry in slot_names.size():
		var name: String = slot_names[entry]
		var widget: WornSlotScript = _slots.get(name)
		if widget == null:
			push_error('EquipmentPanel.apply: unknown worn slot "%s"' % name)
			continue
		widget.show_item(slot_kinds[entry])


## The widget for [param worn], or null when the panel is not drawing one.
func slot_at(worn: String) -> WornSlotScript:
	var slot: WornSlotScript = _slots.get(worn)
	return slot


## What is in [param worn], or "" when it is empty or not drawn.
func kind_in_slot(worn: String) -> String:
	var slot := slot_at(worn)
	return "" if slot == null else slot.kind


func _bind_authored(slot: WornSlotScript, worn_name: String) -> void:
	if slot == null:
		push_error('EquipmentPanel: missing authored slot for "%s"' % worn_name)
		return
	slot.configure(worn_name)
	if _slots.has(worn_name):
		push_error('EquipmentPanel: duplicate authored slot for "%s"' % worn_name)
		return
	_slots[worn_name] = slot
	if not slot.activated.is_connected(_on_worn_activated):
		slot.activated.connect(_on_worn_activated)
	if not slot.equip_from_bag.is_connected(_on_equip_from_bag):
		slot.equip_from_bag.connect(_on_equip_from_bag)


func _on_worn_activated(worn: String) -> void:
	var slot: WornSlotScript = _slots.get(worn)
	if slot == null or not slot.is_occupied():
		push_warning('EquipmentPanel: activate on empty worn slot "%s"' % worn)
		return
	worn_activated.emit(worn)


func _on_equip_from_bag(bag_slot: int) -> void:
	if bag_slot < 0:
		push_error("EquipmentPanel: bag slot indices start at 0, got %d" % bag_slot)
		return
	equip_from_bag.emit(bag_slot)
