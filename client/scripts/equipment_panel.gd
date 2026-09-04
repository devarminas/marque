extends PanelContainer

## What the player is wearing. Authored in `main.tscn`, opened and closed by the
## player. **M3b** panel chrome; **M3c** worn restatement and unequip/drag targets.

const WornSlotScene := preload("res://scenes/worn_slot.tscn")
const WornSlotScript := preload("res://scripts/worn_slot.gd")
const InventorySlotScene := preload("res://scenes/inventory_slot.tscn")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")

const TOGGLE_ACTION := "toggle_equipment"

## Emitted when the player activates an occupied worn slot (`unequip`).
signal worn_activated(worn: String)

## Emitted when a bag slot is dropped onto a worn slot (`equip`).
signal equip_from_bag(bag_slot: int)

@export var slot_rows: VBoxContainer
@export var weapon_slot: WornSlotScript

var _slots := {}


func _ready() -> void:
	if weapon_slot != null:
		weapon_slot.configure("weapon")
		_bind_slot(weapon_slot)


func toggle() -> void:
	visible = not visible


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed(TOGGLE_ACTION):
		return
	toggle()
	get_viewport().set_input_as_handled()


## Applies one `equipment` frame, wholesale.
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

	_sync_worn_slots(worn_names)

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


func _sync_worn_slots(worn_names: PackedStringArray) -> void:
	if slot_rows == null:
		push_error("EquipmentPanel: the scene did not assign slot rows")
		return

	for name: String in worn_names:
		if _slots.has(name):
			continue
		var slot := _make_slot(name)
		if slot == null:
			return
		slot_rows.add_child(slot)
		_bind_slot(slot)


func _make_slot(name: String) -> WornSlotScript:
	if name == "weapon" and weapon_slot != null:
		return weapon_slot

	var slot := WornSlotScene.instantiate() as WornSlotScript
	if slot == null:
		push_error("EquipmentPanel: worn_slot.tscn did not instantiate as a WornSlot")
		return null
	slot.name = "%sSlot" % name.capitalize()
	slot.configure(name)
	return slot


func _bind_slot(slot: WornSlotScript) -> void:
	if slot.worn_name.is_empty():
		return
	if _slots.has(slot.worn_name):
		return
	_slots[slot.worn_name] = slot
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
