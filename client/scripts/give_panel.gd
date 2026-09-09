extends PanelContainer


const InventorySlotScene := preload("res://scenes/inventory_slot.tscn")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")

signal offer_chosen(npc_id: int, slot: int)

signal cancelled()

@export var slot_grid: GridContainer
@export var cancel_button: Button

var _npc_id := 0
var _slots := {}


func _ready() -> void:
	if slot_grid == null or cancel_button == null:
		push_error("GivePanel: the scene did not assign slot_grid and cancel_button")
		return
	cancel_button.pressed.connect(_on_cancel_pressed)


func apply(
	npc_id: int,
	bag_size: int,
	slot_indices: PackedInt32Array,
	slot_kinds: PackedStringArray,
) -> void:
	if npc_id <= 0:
		push_error("GivePanel.apply: npc ids start at 1, got %d" % npc_id)
		return
	if bag_size < 0:
		push_error("GivePanel.apply: size is negative (%d)" % bag_size)
		return
	if slot_indices.size() != slot_kinds.size():
		push_error(
			"GivePanel.apply: %d index(es) against %d kind(s)"
			% [slot_indices.size(), slot_kinds.size()]
		)
		return

	_npc_id = npc_id
	visible = true
	_rebuild_offers(bag_size, slot_indices, slot_kinds)


func clear() -> void:
	_npc_id = 0
	visible = false
	_clear_slots()


func npc_id() -> int:
	return _npc_id


func slot_count() -> int:
	return _slots.size()


func slot_at(index: int) -> InventorySlotScript:
	var slot: InventorySlotScript = _slots.get(index)
	return slot


func kind_in_slot(index: int) -> String:
	var slot := slot_at(index)
	return "" if slot == null else slot.kind


func _rebuild_offers(
	bag_size: int,
	slot_indices: PackedInt32Array,
	slot_kinds: PackedStringArray,
) -> void:
	_clear_slots()
	if slot_grid == null:
		push_error("GivePanel: the scene did not assign a slot grid")
		return

	for entry in slot_indices.size():
		var index := slot_indices[entry]
		if index < 0 or index >= bag_size:
			push_error("GivePanel.apply: slot %d is outside 0..%d" % [index, bag_size - 1])
			continue
		var slot := InventorySlotScene.instantiate() as InventorySlotScript
		if slot == null:
			push_error("GivePanel: inventory_slot.tscn did not instantiate as a slot")
			return
		slot.name = "Slot%d" % index
		slot.configure(index)
		slot.show_item(slot_kinds[entry])
		slot.pressed.connect(_on_slot_pressed.bind(index))
		slot_grid.add_child(slot)
		_slots[index] = slot


func _clear_slots() -> void:
	if slot_grid != null:
		for child in slot_grid.get_children():
			slot_grid.remove_child(child)
			child.queue_free()
	_slots.clear()


func _on_slot_pressed(index: int) -> void:
	if _npc_id <= 0:
		return
	var slot := slot_at(index)
	if slot == null:
		push_error("GivePanel: slot %d was pressed but is not drawn" % index)
		return
	if not slot.is_occupied():
		return
	offer_chosen.emit(_npc_id, index)


func _on_cancel_pressed() -> void:
	cancelled.emit()
