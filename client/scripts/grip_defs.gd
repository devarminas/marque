extends RefCounted


const OFF_HAND := "left hand"
const GRIP_HAND := "right hand"


static func grip_plan(
	slot_names: PackedStringArray, slot_kinds: PackedStringArray
) -> Dictionary:
	var plan := {OFF_HAND: "", GRIP_HAND: ""}
	if slot_names.size() != slot_kinds.size():
		push_error(
			"grip_defs: equipment named %d worn slot(s) but %d kind(s)"
			% [slot_names.size(), slot_kinds.size()]
		)
		return plan
	for index in slot_names.size():
		var slot := slot_names[index]
		if plan.has(slot):
			plan[slot] = slot_kinds[index]
	if plan[OFF_HAND] == plan[GRIP_HAND]:
		plan[OFF_HAND] = ""
	return plan


static func names_the_hands(worn_names: PackedStringArray) -> bool:
	return worn_names.has(OFF_HAND) and worn_names.has(GRIP_HAND)


static func hands() -> PackedStringArray:
	return PackedStringArray([OFF_HAND, GRIP_HAND])
