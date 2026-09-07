extends RefCounted


const KNOWN: PackedStringArray = ["tree"]


static func is_known(kind: String) -> bool:
	return kind in KNOWN
