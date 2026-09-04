extends PanelContainer

## The player's inventory, as the server last stated it. Authored in
## `main.tscn`; the wire format is `PROTOCOL.md`, `inventory`.

const InventorySlotScene := preload("res://scenes/inventory_slot.tscn")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")

## Emitted when the player left-clicks an occupied slot. [param slot] is a slot
## index, never an item id (`PROTOCOL.md`, `drop`).
signal slot_activated(slot: int)

## Emitted when the player right-clicks an occupied slot or drags it onto a
## worn slot. [param slot] is a bag index (`PROTOCOL.md`, `equip`).
signal equip_requested(slot: int)

@export var slot_grid: GridContainer
@export var heading: Label
@export var unknown_heading := "Inventory —"

var _size := 0
var _slots := {}


## Applies one `inventory` frame, wholesale.
##
## [param slot_indices] and [param slot_kinds] are index aligned and sparse:
## they name only the occupied slots. [param size] is how many slots to draw,
## which is not `slot_indices.size()`.
func apply(size: int, slot_indices: PackedInt32Array, slot_kinds: PackedStringArray) -> void:
	if size < 0:
		push_error("InventoryPanel.apply: size is negative (%d)" % size)
		return
	if slot_indices.size() != slot_kinds.size():
		push_error(
			"InventoryPanel.apply: %d index(es) against %d kind(s)"
			% [slot_indices.size(), slot_kinds.size()]
		)
		return

	_rebuild(size)
	for entry in slot_indices.size():
		var index := slot_indices[entry]
		var slot: InventorySlotScript = _slots.get(index)
		if slot == null:
			push_error("InventoryPanel.apply: slot %d is outside 0..%d" % [index, size - 1])
			continue
		slot.show_item(slot_kinds[entry])

	_update_heading(slot_indices.size())


## Drops back to the uninformed state: no slots, and a heading that says so.
func clear() -> void:
	_rebuild(0)
	if heading != null:
		heading.text = unknown_heading


## How many slots are drawn, as the last `inventory` stated.
func slot_count() -> int:
	return _size


## The widget for [param index], or null when the panel is not drawing one.
func slot_at(index: int) -> InventorySlotScript:
	var slot: InventorySlotScript = _slots.get(index)
	return slot


## What is in [param index], or "" when it is empty or not drawn.
func kind_in_slot(index: int) -> String:
	var slot := slot_at(index)
	return "" if slot == null else slot.kind


func occupied_slot_count() -> int:
	var occupied := 0
	for index: int in _slots:
		var slot: InventorySlotScript = _slots[index]
		if slot.is_occupied():
			occupied += 1
	return occupied


## Discards every slot widget and builds [param size] empty ones.
##
## `queue_free` is deferred, so children are removed from the tree first: a
## caller counting the grid's children in the same frame must see the new count.
func _rebuild(size: int) -> void:
	if slot_grid == null:
		push_error("InventoryPanel: the scene did not assign a slot grid")
		return

	for child in slot_grid.get_children():
		slot_grid.remove_child(child)
		child.queue_free()
	_slots.clear()
	_size = size
	visible = size > 0

	for index in size:
		var slot := InventorySlotScene.instantiate() as InventorySlotScript
		if slot == null:
			push_error("InventoryPanel: inventory_slot.tscn did not instantiate as a slot")
			_size = index
			return
		slot.name = "Slot%d" % index
		slot.configure(index)
		slot.pressed.connect(_on_slot_pressed.bind(index))
		slot.equip_requested.connect(_on_slot_equip_requested)
		slot_grid.add_child(slot)
		_slots[index] = slot


func _on_slot_pressed(index: int) -> void:
	var slot := slot_at(index)
	if slot == null:
		push_error("InventoryPanel: slot %d was pressed but is not drawn" % index)
		return
	if not slot.is_occupied():
		push_warning("InventoryPanel: slot %d is empty; not dropping anything" % index)
		return
	slot_activated.emit(index)


func _on_slot_equip_requested(slot: int) -> void:
	if slot < 0:
		push_error("InventoryPanel: bag slot indices start at 0, got %d" % slot)
		return
	equip_requested.emit(slot)


func _update_heading(occupied: int) -> void:
	if heading == null:
		return
	heading.text = "Inventory %d/%d" % [occupied, _size]
