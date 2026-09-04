extends RefCounted

## The item type names this client has art for. One list, read by everything
## that has to draw an item.
##
## M1 ships exactly one (PROTOCOL.md, `item_spawn`). Anything else renders
## magenta rather than nothing, because a missing asset must scream (NOTES.md,
## "Color as semantics") and because unknown kinds are how content is added
## without a client release. That path is the one that has to work when a server
## learns a second kind before this client does, so it is tested rather than
## assumed.
##
## [b]It lives here rather than on either drawer.[/b] `ground_item.gd` draws a
## kind lying in the world and `inventory_slot.gd` draws the same kind held in a
## panel, and a second copy of this list would let one call a kind known while
## the other called it missing — the same acorn green on the grass and magenta
## in the bag. That is a bug nobody would think to look for.
##
## Never instantiated. Typed by [code]preload[/code], per NOTES.md, "Godot
## authoring traps":
##
## [codeblock]
## const ItemKinds := preload("res://scripts/item_kinds.gd")
## if ItemKinds.is_known(kind): ...
## [/codeblock]

## Every kind this client can draw.
const KNOWN: PackedStringArray = ["acorn", "axe"]


## True when this client has art for [param kind]. An unknown kind is not an
## error anywhere; it is drawn magenta and the game keeps going.
static func is_known(kind: String) -> bool:
	return kind in KNOWN
