extends RefCounted

## Resource-node type names this client has art for. **M4b.**
##
## M4a ships exactly one kind, `tree` (`PROTOCOL.md`, `node_spawn`). Unknown
## kinds render magenta and keep going, the same rule as item kinds.

const KNOWN: PackedStringArray = ["tree"]


static func is_known(kind: String) -> bool:
	return kind in KNOWN
