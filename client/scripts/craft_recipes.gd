extends RefCounted

## Client mirror of server bag and station recipes in craft.go / stations.go.
## Used for Use-mode highlights. Does not predict inventory mutations.


const BAG := [
	{"consumes": ["logs"], "produce": "sticks"},
	{"consumes": ["copper_bar", "sticks"], "produce": "sword"},
]

const STATION := [
	{"station": "smelter", "consume": "copper_ore", "produce": "copper_bar"},
]


static func bag_recipe_for(kind: String) -> Dictionary:
	if kind.is_empty():
		return {}
	for recipe: Dictionary in BAG:
		var consumes: Array = recipe["consumes"]
		if consumes.has(kind):
			return recipe
	return {}


static func station_kind_for(consume_kind: String) -> String:
	if consume_kind.is_empty():
		return ""
	for recipe: Dictionary in STATION:
		if String(recipe["consume"]) == consume_kind:
			return String(recipe["station"])
	return ""


static func station_produce(station_kind: String, consume_kind: String) -> String:
	if station_kind.is_empty() or consume_kind.is_empty():
		return ""
	for recipe: Dictionary in STATION:
		if String(recipe["station"]) == station_kind and String(recipe["consume"]) == consume_kind:
			return String(recipe["produce"])
	return ""


static func partner_slots(
	source: int, source_kind: String, indices: PackedInt32Array, kinds: PackedStringArray
) -> PackedInt32Array:
	var found := PackedInt32Array()
	var recipe := bag_recipe_for(source_kind)
	if recipe.is_empty() or indices.size() != kinds.size():
		return found

	var source_held := false
	for entry in indices.size():
		if int(indices[entry]) == source:
			source_held = true
			break
	if not source_held:
		return found

	var remaining := {}
	var skipped_primary := false
	for need: String in recipe["consumes"]:
		if not skipped_primary and need == source_kind:
			skipped_primary = true
			continue
		remaining[need] = int(remaining.get(need, 0)) + 1

	for entry in indices.size():
		var slot := int(indices[entry])
		if slot == source:
			continue
		var kind := String(kinds[entry])
		var left := int(remaining.get(kind, 0))
		if left <= 0:
			continue
		remaining[kind] = left - 1
		found.append(slot)

	var complete := true
	for need: Variant in remaining.keys():
		if int(remaining[need]) > 0:
			complete = false
			break
	if complete:
		found.append(source)
	return found
