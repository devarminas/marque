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


static func display_name(kind: String) -> String:
	match kind:
		"logs":
			return "Logs"
		"sticks":
			return "Sticks"
		"copper_ore":
			return "Copper ore"
		"copper_bar":
			return "Copper bar"
		"sword":
			return "Sword"
		"smelter":
			return "Smelter"
		_:
			return kind


static func missing_kinds(source_kind: String, kinds: PackedStringArray) -> PackedStringArray:
	var missing := PackedStringArray()
	var recipe := bag_recipe_for(source_kind)
	if recipe.is_empty():
		return missing
	var pool := {}
	for kind: String in kinds:
		pool[kind] = int(pool.get(kind, 0)) + 1
	for need: String in recipe["consumes"]:
		var have := int(pool.get(need, 0))
		if have > 0:
			pool[need] = have - 1
		else:
			missing.append(need)
	return missing


static func bag_preview(source_kind: String, kinds: PackedStringArray) -> Dictionary:
	var recipe := bag_recipe_for(source_kind)
	if recipe.is_empty():
		return {}
	var missing := missing_kinds(source_kind, kinds)
	var text := "Craft → %s" % display_name(String(recipe["produce"]))
	if not missing.is_empty():
		var names := PackedStringArray()
		for kind: String in missing:
			names.append(display_name(kind))
		text = "%s (missing %s)" % [text, ", ".join(names)]
	return {"text": text, "complete": missing.is_empty(), "missing": missing}


static func station_recipes(station_kind: String) -> Array:
	var found: Array = []
	if station_kind.is_empty():
		return found
	for recipe: Dictionary in STATION:
		if String(recipe["station"]) == station_kind:
			found.append(recipe)
	return found


static func station_sheet_rows(station_kind: String, bag_kinds: PackedStringArray) -> Array:
	var ready: Array = []
	var rest: Array = []
	for recipe: Dictionary in station_recipes(station_kind):
		var consume := String(recipe["consume"])
		var produce := String(recipe["produce"])
		var have := false
		for kind: String in bag_kinds:
			if kind == consume:
				have = true
				break
		var row := {
			"text": "%s → %s" % [display_name(consume), display_name(produce)],
			"ready": have,
		}
		if have:
			ready.append(row)
		else:
			rest.append(row)
	return ready + rest


static func station_preview(station_kind: String, consume_kind: String) -> Dictionary:
	var produce := station_produce(station_kind, consume_kind)
	if produce.is_empty():
		return {}
	var verb := "Smelt" if station_kind == "smelter" else "Craft"
	return {
		"text": "%s → %s" % [verb, display_name(produce)],
		"complete": true,
		"missing": PackedStringArray(),
	}
