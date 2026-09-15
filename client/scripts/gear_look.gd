extends RefCounted


const ArtContract := preload("res://scripts/art_contract.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")

const GRIP_NONE := &"none"
const GRIP_ONE := &"one"
const GRIP_TWO := &"two"


class Look:
	extends RefCounted
	var pieces := PackedStringArray()
	var hidden_regions := PackedStringArray()
	var hands := {}
	var grip := GRIP_NONE


static func resolve(
	slot_names: PackedStringArray,
	slot_kinds: PackedStringArray,
	contract: ArtContract,
	sets: Dictionary,
) -> Look:
	var look := Look.new()
	look.hands = GripDefs.grip_plan(slot_names, slot_kinds)
	if slot_names.size() != slot_kinds.size():
		return look
	var hidden := {}
	for index in slot_names.size():
		var slot := slot_names[index]
		var kind := slot_kinds[index]
		if look.hands.has(slot):
			continue
		if not contract.slot_regions.has(slot):
			push_error('gear_look: worn slot "%s" is neither a hand nor a contract body slot' % slot)
			continue
		var piece: ArtContract.Piece = contract.pieces.get(kind)
		if piece == null or piece.slot != slot:
			push_error('gear_look: slot "%s" wears "%s", which the art contract has no piece for' % [slot, kind])
			continue
		look.pieces.append(kind)
		for region in piece.hides:
			hidden[region] = true
	look.pieces.sort()
	look.hidden_regions = PackedStringArray(hidden.keys())
	look.hidden_regions.sort()
	look.grip = _grip_for(look.hands.values(), _two_handed_kinds(sets))
	return look


static func _grip_for(held: Array, two_handed: Dictionary) -> StringName:
	var grip := GRIP_NONE
	for kind: String in held:
		if kind.is_empty():
			continue
		if two_handed.has(kind):
			return GRIP_TWO
		grip = GRIP_ONE
	return grip


static func _two_handed_kinds(sets: Dictionary) -> Dictionary:
	var kinds := {}
	for set_id in ClassDefs.set_ids(sets):
		var tools: Variant = ClassDefs.get_set(sets, set_id).get("tools")
		if typeof(tools) != TYPE_DICTIONARY:
			continue
		for kind: String in tools:
			if String(tools[kind].get("handed", "")) == ClassDefs.HANDED_TWO:
				kinds[kind] = true
	return kinds
