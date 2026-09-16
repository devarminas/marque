extends RefCounted

const ItemKinds := preload("res://scripts/item_kinds.gd")
const Assertions := preload("res://tests/assertions.gd")


func run(assertions: Assertions) -> void:
	_test_display_name_is_the_kind(assertions)
	_test_item_class_from_sets(assertions)
	_test_known_kinds_are_unchanged(assertions)
	assertions.finish()


func _test_display_name_is_the_kind(assertions: Assertions) -> void:
	assertions.check(
		ItemKinds.display_name("sword") == "sword",
		'display_name("sword") is the kind itself, got "%s"' % ItemKinds.display_name("sword"),
	)
	assertions.check(
		ItemKinds.display_name("") == "",
		'display_name("") is empty, got "%s"' % ItemKinds.display_name(""),
	)


func _test_item_class_from_sets(assertions: Assertions) -> void:
	assertions.check(
		ItemKinds.item_class("sword") == "Knight",
		'item_class("sword") is Knight, got "%s"' % ItemKinds.item_class("sword"),
	)
	assertions.check(
		ItemKinds.item_class("lumberjack_axe") == "Lumberjack",
		'item_class("lumberjack_axe") is Lumberjack, got "%s"' % ItemKinds.item_class("lumberjack_axe"),
	)
	assertions.check(
		ItemKinds.item_class("plate_helm") == "Knight",
		'item_class("plate_helm") is Knight, got "%s"' % ItemKinds.item_class("plate_helm"),
	)
	assertions.check(
		ItemKinds.item_class("acorn") == "unknown",
		'item_class("acorn") is unknown, got "%s"' % ItemKinds.item_class("acorn"),
	)
	assertions.check(
		ItemKinds.item_class("bewilderment") == "unknown",
		'item_class("bewilderment") is unknown, got "%s"' % ItemKinds.item_class("bewilderment"),
	)
	assertions.check(
		ItemKinds.item_class("") == "",
		'item_class("") is empty, got "%s"' % ItemKinds.item_class(""),
	)


func _test_known_kinds_are_unchanged(assertions: Assertions) -> void:
	assertions.check(ItemKinds.is_known("acorn"), "acorn stays a known loose kind")
	assertions.check(
		not ItemKinds.is_known("bewilderment"),
		"bewilderment stays unknown",
	)
