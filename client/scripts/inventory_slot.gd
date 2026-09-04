extends Button

## One inventory slot's widget. Instanced once per slot by
## `inventory_panel.gd`.
##
## The scene is [code]res://scenes/inventory_slot.tscn[/code]. How many slots
## exist is on the wire (`PROTOCOL.md`, `inventory`: [code]size[/code]), so it is
## genuine runtime information and instancing per slot is the case CLAUDE.md's
## scene-authoring rule allows — the same split as `ground_item.tscn`, where the
## container is authored and the bodies are not. Its [i]contents[/i] — the fill,
## the label, and all three colours — are authored in the scene file and nothing
## here builds a node.
##
## [b]It draws; it does not decide.[/b] It holds no cached inventory, never
## writes a slot, and never asks anything what it is holding. The panel calls
## [method show_item] or [method show_empty] on it and it obeys, so nothing here
## can drift from what the server last said.
##
## [b]An empty slot is a dead control.[/b] It is [member Button.disabled], so it
## cannot emit [signal BaseButton.pressed] and there is no path from a click on
## one to a `drop` naming an empty slot. The server would refuse that anyway,
## and an intent sent knowing it will be refused is noise on the wire.
##
## Typed by [code]preload[/code] rather than by global [code]class_name[/code],
## per NOTES.md, "Godot authoring traps".

const ItemKinds := preload("res://scripts/item_kinds.gd")

## Emitted on right-click of an occupied slot. The panel forwards it as `equip`.
signal equip_requested(slot: int)

## The slot's index in the inventory, or -1 before [method configure]. This is
## what a `drop` names (`PROTOCOL.md`, `drop`), so it is the slot's identity and
## not a display detail.
var slot_index := -1

## What is in the slot, or "" when it is empty. Held verbatim, including a kind
## this client has no art for: the server's name for the thing is worth more in
## a log than this client's opinion of it.
var kind := ""

## The square of colour that makes the slot readable at a glance. Authored in
## the scene; assigned by [code]node_paths[/code] on the [code][node][/code]
## header, without which an exported node path silently resolves to null
## (NOTES.md).
@export var fill: ColorRect

## Names the kind when the slot is occupied and the slot index when it is not,
## so every square in the grid says which one it is.
@export var label: Label

## Drawn for an empty slot. Gray is static world geometry (NOTES.md, "Color as
## semantics") and, more to the point, it is nothing like the two below.
@export var empty_color: Color

## Drawn for a kind in [constant ItemKinds.KNOWN]. Green is Pickup.
@export var known_color: Color

## Drawn for anything else. Magenta is missing-asset, and it must scream.
@export var unknown_color: Color


## Binds this widget to a slot index and shows it empty.
##
## Called once, immediately after instancing and before the widget enters the
## tree, so a slot is never drawn for a frame under the wrong index.
func configure(index: int) -> void:
	if index < 0:
		push_error("InventorySlot.configure: slot indices start at 0, got %d" % index)
		return
	slot_index = index
	show_empty()


## Draws the slot holding [param item_kind].
##
## An unknown kind is not refused: it is drawn magenta and named, because
## unknown kinds are how content is added without a client release
## (`PROTOCOL.md`, `item_spawn`).
func show_item(item_kind: String) -> void:
	kind = item_kind
	disabled = false
	if not ItemKinds.is_known(item_kind):
		push_warning(
			'InventorySlot: slot %d holds unknown kind "%s"; drawing it magenta'
			% [slot_index, item_kind]
		)
	_paint(known_color if ItemKinds.is_known(item_kind) else unknown_color, item_kind)


## Draws the slot empty. An empty slot is absent from the wire rather than null
## (`PROTOCOL.md`, `inventory`), so this is what the panel does to every index
## the frame did not mention.
func show_empty() -> void:
	kind = ""
	disabled = true
	_paint(empty_color, str(slot_index))


## True when this slot holds something.
func is_occupied() -> bool:
	return not kind.is_empty()


## The colour this widget is actually drawing, as opposed to the one it meant
## to.
##
## Read off the [ColorRect] rather than recomputed, so a test asserting "an
## unknown kind is magenta" asserts what a screenshot would show rather than
## what [method show_item] intended.
func display_color() -> Color:
	if fill == null:
		return Color(0, 0, 0, 0)
	return fill.color


func _gui_input(event: InputEvent) -> void:
	if not is_occupied():
		return
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_RIGHT
	):
		equip_requested.emit(slot_index)
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
