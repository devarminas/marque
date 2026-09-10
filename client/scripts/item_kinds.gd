extends RefCounted


const ClassDefs := preload("res://scripts/class_defs.gd")

const LOOSE_KINDS: PackedStringArray = ["acorn", "logs", "sticks", "copper_ore"]

static var _known := PackedStringArray()
static var _resolved := false


static func known() -> PackedStringArray:
	if not _resolved:
		_known = _resolve()
		_resolved = true
	return _known


static func is_known(kind: String) -> bool:
	return kind in known()


static func _resolve() -> PackedStringArray:
	var kinds := ClassDefs.wearable_kinds(ClassDefs.load_sets())
	for kind: String in LOOSE_KINDS:
		if not kinds.has(kind):
			kinds.append(kind)
	kinds.sort()
	return kinds
