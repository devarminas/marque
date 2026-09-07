extends RefCounted


const KNOWN: PackedStringArray = ["acorn", "axe"]


static func is_known(kind: String) -> bool:
	return kind in KNOWN
