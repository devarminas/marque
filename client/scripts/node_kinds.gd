extends RefCounted


const KIND_TREE := "tree"
const KIND_ROCK := "rock"
const KIND_SMELTER := "smelter"

const KNOWN: PackedStringArray = [KIND_TREE, KIND_ROCK, KIND_SMELTER]


static func is_known(kind: String) -> bool:
	return kind in KNOWN


static func is_gatherable(kind: String) -> bool:
	return kind == KIND_TREE or kind == KIND_ROCK


static func is_station(kind: String) -> bool:
	return kind == KIND_SMELTER
