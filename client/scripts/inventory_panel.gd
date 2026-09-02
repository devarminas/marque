extends PanelContainer

## The player's inventory, as the server last stated it.
##
## [b]It is authored in [code]main.tscn[/code].[/b] There is exactly one
## inventory panel per world, so the panel, its heading, and the grid its slots
## sit in are static content and belong in the scene file (CLAUDE.md, "Scene
## authoring"). Only the slots are built here, and only because how many there
## are arrives on the wire: `inventory.size` (`PROTOCOL.md`, `inventory`). That
## is the same split `main.tscn` already makes for `GroundItems` — an authored
## container whose children are runtime.
##
## [b]`inventory` is a full restatement, not a patch.[/b] So [method apply]
## rebuilds instead of diffing. A diff would have to be right about what it
## believed beforehand, and this panel is a cache of somebody else's state with
## no authority over it; rebuilding cannot drift, and it is twenty-eight widgets.
##
## [b]No slot holds an item id, because there is no id to hold.[/b] An inventory
## holds kinds; once an item is carried, the id it had on the ground is gone and
## a dropped item gets a fresh one (`PROTOCOL.md`, *Drop*). So a slot is a kind
## and an index, `drop` names the index, and nothing here could accidentally
## key a carried item to a body in the world.
##
## [b]It never predicts.[/b] Nothing here writes a slot in response to a click.
## Clicking an occupied slot emits [signal slot_activated], `session.gd` turns
## that into a `drop` intent, and this panel changes only when the `inventory`
## the server sends back says it changed. A panel that emptied the slot on click
## would be showing a fact the client invented, and it would be wrong every time
## the server refused (CLAUDE.md, "Client sends intents, never facts").
##
## [b]The panel is opaque.[/b] It is authored with
## [constant Control.MOUSE_FILTER_STOP], so every click inside its drawn rect
## stops here: an occupied slot drops, and everything else — chrome, margin,
## heading, an empty slot — is swallowed. Nothing behind the panel is reachable
## through it, which is RuneScape's sidebar and so is the answer this game takes
## (STANDING-ORDERS.md, "Deciding without the human").
##
## Exactly one [i]chrome[/i] node blocks, and it is this one — the slot
## [Button]s block too, which is how a drop happens at all. [code]Margin[/code],
## [code]Rows[/code] and [code]Slots[/code] stay
## [constant Control.MOUSE_FILTER_IGNORE], so a click that misses a slot falls
## past them to the panel instead of being caught by whichever container
## happened to be under the cursor. Where a missed click stops is then a
## property of the panel alone, and rearranging the containers cannot change it.
##
## [b]M1d shipped the opposite[/b], the whole chrome IGNORE, because a headless
## Godot viewport is 64x64 (NOTES.md) and this panel covers all but a 16px strip
## of it: an opaque panel left no world for the older suites to click. That was
## a test-harness workaround wearing the shape of a design decision, and M1k
## undid it. `test_wiring.gd`'s live click now aims at the strip the panel does
## not cover, which is what its [code]CLICK_AT[/code] is for;
## `test_interaction.gd` clicks the panel on purpose instead.
##
## [b]It listens to nothing.[/b] `session.gd` owns every connection between the
## network and the scene, and it calls [method apply] and hears
## [signal slot_activated]. A panel that subscribed to `net_client.gd` itself
## would be a second node reaching into the network, and it could not be tested
## without one.
##
## Typed by [code]preload[/code] rather than by global [code]class_name[/code],
## per NOTES.md, "Godot authoring traps".

const InventorySlotScene := preload("res://scenes/inventory_slot.tscn")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")

## Emitted when the player clicks an occupied slot. [param slot] is the slot's
## index, which is what `drop` names — never an item id (`PROTOCOL.md`, `drop`).
##
## Empty slots are disabled and cannot emit this.
signal slot_activated(slot: int)

## The container the slots are instanced into. Authored in `main.tscn`; assigned
## by [code]node_paths[/code] on the [code][node][/code] header, without which
## an exported node path silently resolves to null (NOTES.md).
@export var slot_grid: GridContainer

## Says how full the inventory is. Authored; only its text changes.
@export var heading: Label

## Shown before the first `inventory` frame. The panel is not empty at that
## point, it is [i]uninformed[/i], and those are different states: an inventory
## with nothing in it is something the server said, and this is the absence of
## anything said at all.
@export var unknown_heading := "Inventory —"

var _size := 0
## Slot index to widget, for every index in [code]0.._size - 1[/code]. Dense,
## unlike the wire, because every slot is drawn whether or not it is occupied.
var _slots := {}


## Applies one `inventory` frame, wholesale.
##
## [param slot_indices] and [param slot_kinds] are index aligned and
## [b]sparse[/b]: they name only the occupied slots, each carrying its own
## index, and empty slots are absent rather than null (`PROTOCOL.md`,
## `inventory`). So `slot_indices.size()` is how much the player is carrying and
## [param size] is how many slots to draw; conflating the two draws the wrong
## grid.
##
## `net_client.gd` has already refused any frame whose index falls outside
## `0..size - 1` or names a slot twice, so the guards below are this panel
## refusing to draw a world it was never handed rather than a second copy of the
## protocol check.
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
##
## Called on `welcome`, which restates the world. The player's inventory is not
## part of `welcome` — it is private to one player and arrives as its own
## message inside the same atomic step (`PROTOCOL.md`, `welcome`) — so for the
## frame or two in between, showing the previous session's inventory would be
## showing something nobody has claimed is true.
func clear() -> void:
	_rebuild(0)
	if heading != null:
		heading.text = unknown_heading


## How many slots are drawn. The number the last `inventory` gave, not 28: the
## count is on the wire precisely so this client draws the grid it is told to
## draw (`PROTOCOL.md`, `inventory`).
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


## How many drawn slots are occupied.
func occupied_slot_count() -> int:
	var occupied := 0
	for index: int in _slots:
		var slot: InventorySlotScript = _slots[index]
		if slot.is_occupied():
			occupied += 1
	return occupied


## Discards every slot widget and builds [param size] empty ones.
##
## Freeing and rebuilding on every frame is the point rather than an oversight;
## see the class docs. The children are removed from the tree before they are
## queued so that a caller counting the grid's children in the same frame sees
## the truth — the same reason `session.gd` does it for bodies.
##
## [b]A panel with no slots is hidden, not drawn empty.[/b] There is nothing to
## show before the first `inventory`, and an empty box is not an inventory with
## nothing in it — it is the absence of anything the server has said. It also
## has teeth, and more of them since M1k: this panel is opaque, so a panel drawn
## while the client is uninformed would sit in front of the world swallowing
## every click inside its rect for as long as the client stays offline. Hiding
## it is what keeps the world clickable before the first frame arrives.
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
		# Configured before it enters the tree, so it is never drawn for a frame
		# under the wrong index.
		slot.configure(index)
		slot.pressed.connect(_on_slot_pressed.bind(index))
		slot_grid.add_child(slot)
		_slots[index] = slot


func _on_slot_pressed(index: int) -> void:
	var slot := slot_at(index)
	if slot == null:
		push_error("InventoryPanel: slot %d was pressed but is not drawn" % index)
		return
	# Belt and braces: an empty slot's widget is disabled and cannot fire this,
	# and a `drop` naming an empty slot would be an intent sent knowing the
	# server will refuse it.
	if not slot.is_occupied():
		push_warning("InventoryPanel: slot %d is empty; not dropping anything" % index)
		return
	slot_activated.emit(index)


func _update_heading(occupied: int) -> void:
	if heading == null:
		return
	heading.text = "Inventory %d/%d" % [occupied, _size]
