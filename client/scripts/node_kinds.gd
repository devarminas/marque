extends RefCounted


const KIND_TREE := "tree"
const KIND_ROCK := "rock"

const KNOWN: PackedStringArray = [KIND_TREE, KIND_ROCK]


static func is_known(kind: String) -> bool:
	return kind in KNOWN
