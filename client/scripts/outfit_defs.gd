extends RefCounted


const PEASANT := "peasant"
const RANGER := "ranger"

const DRESSED_GIRTH := 0.78
const BARE_GIRTH := 1.0

const PARTS := {
	PEASANT: ["PeasantBody", "PeasantArms", "PeasantLegs", "PeasantFeet"],
	RANGER: [
		"RangerBody", "RangerArms", "RangerLegs", "RangerFeet", "RangerHood", "RangerPauldron"
	],
}

const BY_CLASS := {
	"archer": {"outfit": RANGER, "tint": Color(0.95, 1.45, 0.80)},
	"knight": {"outfit": RANGER, "tint": Color(0.34, 0.44, 0.78)},
	"mage": {"outfit": PEASANT, "tint": Color(0.62, 0.50, 1.00)},
	"miner": {"outfit": PEASANT, "tint": Color(1.00, 0.72, 0.36)},
	"lumberjack": {"outfit": PEASANT, "tint": Color(0.42, 0.78, 0.34)},
}


static func outfit_for(class_id: String) -> String:
	var entry: Variant = BY_CLASS.get(class_id)
	if typeof(entry) != TYPE_DICTIONARY:
		return ""
	var outfit: Variant = entry.get("outfit", "")
	if typeof(outfit) != TYPE_STRING or not PARTS.has(outfit):
		return ""
	return outfit


static func tint_for(class_id: String) -> Color:
	var entry: Variant = BY_CLASS.get(class_id)
	if typeof(entry) != TYPE_DICTIONARY:
		return Color.WHITE
	var tint: Variant = entry.get("tint", Color.WHITE)
	if typeof(tint) != TYPE_COLOR:
		return Color.WHITE
	return tint


static func girth_for(class_id: String) -> float:
	if outfit_for(class_id).is_empty():
		return BARE_GIRTH
	return DRESSED_GIRTH


static func part_names() -> PackedStringArray:
	var names := PackedStringArray()
	for outfit: String in PARTS:
		names.append_array(parts_of(outfit))
	return names


static func parts_of(outfit: String) -> PackedStringArray:
	if not PARTS.has(outfit):
		return PackedStringArray()
	return PackedStringArray(PARTS[outfit])


static func parts_for(class_id: String) -> PackedStringArray:
	return parts_of(outfit_for(class_id))
