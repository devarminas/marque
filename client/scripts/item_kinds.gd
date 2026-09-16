extends RefCounted


const ClassDefs := preload("res://scripts/class_defs.gd")

const LOOSE_KINDS: PackedStringArray = ["acorn", "logs", "sticks", "copper_ore", "copper_bar"]

static var _known := PackedStringArray()
static var _resolved := false

static var _kind_class := {}
static var _class_resolved := false


static func known() -> PackedStringArray:
	if not _resolved:
		_known = _resolve()
		_resolved = true
	return _known


static func is_known(kind: String) -> bool:
	return kind in known()


static func display_name(kind: String) -> String:
	return kind


static func item_class(kind: String) -> String:
	if kind.is_empty():
		return ""
	return String(_classes().get(kind, "unknown"))


static func _classes() -> Dictionary:
	if not _class_resolved:
		_kind_class = _resolve_classes()
		_class_resolved = true
	return _kind_class


static func _resolve_classes() -> Dictionary:
	var by_kind := {}
	var catalog := ClassDefs.load_sets()
	var by_id: Dictionary = catalog.get("by_set_id", {})
	for set_id: Variant in by_id.keys():
		var entry: Variant = by_id[set_id]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var record: Dictionary = entry
		var set_name := String(record.get("name", ""))
		var slots: Variant = record.get("slots")
		if typeof(slots) == TYPE_DICTIONARY:
			for kind: Variant in (slots as Dictionary).values():
				if typeof(kind) == TYPE_STRING and not String(kind).is_empty():
					by_kind[String(kind)] = set_name
		var tools: Variant = record.get("tools")
		if typeof(tools) == TYPE_DICTIONARY:
			for kind: Variant in (tools as Dictionary).keys():
				if typeof(kind) == TYPE_STRING and not String(kind).is_empty():
					by_kind[String(kind)] = set_name
	return by_kind


static func _resolve() -> PackedStringArray:
	var kinds := ClassDefs.wearable_kinds(ClassDefs.load_sets())
	for kind: String in LOOSE_KINDS:
		if not kinds.has(kind):
			kinds.append(kind)
	kinds.sort()
	return kinds
