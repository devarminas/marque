extends Node3D


const InventorySlotScene := preload("res://scenes/inventory_slot.tscn")
const InventorySlotScript := preload("res://scripts/inventory_slot.gd")
const Assertions := preload("res://tests/assertions.gd")

const SLOT_SCRIPT_PATH := "res://scripts/inventory_slot.gd"

var _assertions := Assertions.new()
var _finished := false
var _layer: CanvasLayer = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== inventory hover: occupied bag slots pop a tooltip ==")
	_layer = CanvasLayer.new()
	add_child(_layer)

	_test_the_popup_is_authored_before_anything_runs()

	var slot := _fresh_slot()
	await get_tree().process_frame

	_test_occupied_sword_shows_immediately(slot)
	_test_show_item_while_inside_refreshes(slot)
	_test_pointer_exit_hides_immediately(slot)
	_test_empty_slot_stays_silent(slot)
	_test_clearing_while_inside_hides(slot)
	_test_unknown_kind_is_honest(slot)
	_test_script_has_no_tween_or_native_tooltip()
	_test_right_click_still_requests_equip()

	print(
		"INVENTORY HOVER RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_popup_is_authored_before_anything_runs() -> void:
	var unopened := InventorySlotScene.instantiate() as InventorySlotScript
	_check(unopened != null, "inventory_slot.tscn instantiates as a slot")
	if unopened == null:
		return
	var popup := unopened.get_node_or_null("HoverPopup") as PanelContainer
	_check(popup != null, "inventory_slot.tscn authors HoverPopup before any _ready runs")
	_check(
		popup != null and not popup.visible,
		"and the scene file is what starts it hidden",
	)
	_check(
		unopened.hover_popup == popup,
		"and the slot export points at that authored popup",
	)
	_check(
		unopened.hover_image != null and unopened.hover_name != null and unopened.hover_class != null,
		"and the scene assigned hover image, name, and class",
	)
	_check(unopened.tooltip_text.is_empty(), "and tooltip_text starts empty")
	var highlight := unopened.get_node_or_null("UseHighlight") as ColorRect
	_check(highlight != null, "inventory_slot.tscn authors UseHighlight")
	_check(
		highlight != null and not highlight.visible,
		"and the scene file is what starts the Use chrome hidden",
	)
	_check(
		unopened.use_highlight == highlight,
		"and the slot export points at that authored highlight",
	)
	unopened.queue_free()


func _test_occupied_sword_shows_immediately(slot: InventorySlotScript) -> void:
	slot.show_item("sword")
	_enter(slot)
	_check(
		slot.hover_popup.visible,
		"occupied sword: pointer enter shows the popup in the same call",
	)
	_check(
		slot.hover_name.text == "sword",
		'occupied sword: name label is "sword", got "%s"' % slot.hover_name.text,
	)
	_check(
		slot.hover_class.text == "Knight",
		'occupied sword: class label is "Knight", got "%s"' % slot.hover_class.text,
	)
	_check(
		slot.hover_image.color == slot.known_color,
		"occupied sword: image matches known_color %s, got %s"
		% [slot.known_color, slot.hover_image.color],
	)
	_check(
		slot.tooltip_text.is_empty(),
		'occupied sword: tooltip_text stays empty, got "%s"' % slot.tooltip_text,
	)
	_check(
		is_equal_approx(slot.hover_popup.modulate.a, 1.0),
		"occupied sword: popup modulate.a is 1.0 while shown, got %f" % slot.hover_popup.modulate.a,
	)


func _test_show_item_while_inside_refreshes(slot: InventorySlotScript) -> void:
	_check(slot.hover_popup.visible, "refresh starts from a shown occupied popup")
	slot.show_item("lumberjack_axe")
	_check(
		slot.hover_popup.visible,
		"show_item while the pointer is inside keeps the popup shown",
	)
	_check(
		slot.hover_name.text == "lumberjack_axe",
		'show_item while inside refreshes the name to "lumberjack_axe", got "%s"'
		% slot.hover_name.text,
	)
	_check(
		slot.hover_class.text == "Lumberjack",
		'show_item while inside refreshes the class to "Lumberjack", got "%s"'
		% slot.hover_class.text,
	)
	slot.show_item("sword")
	_check(
		slot.hover_name.text == "sword" and slot.hover_class.text == "Knight",
		"and a second show_item restores sword / Knight, got %s / %s"
		% [slot.hover_name.text, slot.hover_class.text],
	)


func _test_pointer_exit_hides_immediately(slot: InventorySlotScript) -> void:
	_check(slot.hover_popup.visible, "pointer exit starts from a shown popup")
	_exit(slot)
	_check(
		not slot.hover_popup.visible,
		"pointer exit hides the popup immediately",
	)


func _test_empty_slot_stays_silent(slot: InventorySlotScript) -> void:
	slot.show_empty()
	_enter(slot)
	_check(
		not slot.hover_popup.visible,
		"empty slot: pointer enter keeps the popup hidden",
	)
	_exit(slot)


func _test_clearing_while_inside_hides(slot: InventorySlotScript) -> void:
	slot.show_item("sword")
	_enter(slot)
	_check(slot.hover_popup.visible, "clear-while-inside starts from a shown occupied popup")
	slot.show_empty()
	_check(
		not slot.hover_popup.visible,
		"show_empty while the pointer is inside hides the popup",
	)
	_exit(slot)


func _test_unknown_kind_is_honest(slot: InventorySlotScript) -> void:
	slot.show_item("bewilderment")
	_enter(slot)
	_check(
		slot.hover_popup.visible,
		"unknown kind: occupied hover still shows the popup",
	)
	_check(
		slot.hover_image.color == slot.unknown_color,
		"unknown kind: image matches unknown_color %s, got %s"
		% [slot.unknown_color, slot.hover_image.color],
	)
	_check(
		slot.hover_name.text == "bewilderment",
		'unknown kind: name is "bewilderment", got "%s"' % slot.hover_name.text,
	)
	_check(
		slot.hover_class.text == "unknown",
		'unknown kind: class is "unknown", got "%s"' % slot.hover_class.text,
	)
	_exit(slot)


func _test_script_has_no_tween_or_native_tooltip() -> void:
	var source := FileAccess.get_file_as_string(SLOT_SCRIPT_PATH)
	_check(not source.is_empty(), "can read %s" % SLOT_SCRIPT_PATH)
	_check(
		not source.contains("create_tween"),
		"inventory_slot.gd does not call create_tween",
	)
	_check(
		not source.contains("Tween"),
		"inventory_slot.gd does not name Tween",
	)
	_check(
		not source.contains("tooltip_text"),
		"inventory_slot.gd does not assign tooltip_text",
	)


func _test_right_click_still_requests_equip() -> void:
	var slot := _fresh_slot()
	slot.configure(4)
	slot.show_item("sword")
	var got := PackedInt32Array()
	slot.equip_requested.connect(func(index: int) -> void: got.append(index))
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_RIGHT
	button.pressed = true
	slot._gui_input(button)
	_check(
		got.size() == 1 and got[0] == 4,
		"occupied slot still emits equip_requested(4) on right-click, got %s" % [got],
	)
	slot.queue_free()


func _fresh_slot() -> InventorySlotScript:
	var slot := InventorySlotScene.instantiate() as InventorySlotScript
	_layer.add_child(slot)
	slot.position = Vector2(400, 200)
	slot.configure(0)
	return slot


func _enter(slot: InventorySlotScript) -> void:
	slot.notification(Control.NOTIFICATION_MOUSE_ENTER)
	slot.mouse_entered.emit()


func _exit(slot: InventorySlotScript) -> void:
	slot.notification(Control.NOTIFICATION_MOUSE_EXIT)
	slot.mouse_exited.emit()


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
