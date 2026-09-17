extends RefCounted


const ClassDefs := preload("res://scripts/class_defs.gd")

const WEAPONS_REL_PATH := "shared/weapons.json"


static func load_attack_period_ticks() -> Dictionary:
	var path := ClassDefs.resolve_path(WEAPONS_REL_PATH, "MARQUE_WEAPONS")
	if path.is_empty():
		push_error("weapon_defs: %s not found (set MARQUE_WEAPONS)" % WEAPONS_REL_PATH)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("weapon_defs: could not open %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return {}
	return parse_attack_period_ticks(file.get_as_text(), path)


static func parse_attack_period_ticks(text: String, source: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("weapons")) != TYPE_ARRAY:
		push_error("weapon_defs: %s has no weapons array" % source)
		return {}
	var periods := {}
	for entry: Variant in parsed["weapons"]:
		if (
			typeof(entry) != TYPE_DICTIONARY
			or typeof(entry.get("id")) != TYPE_STRING
			or typeof(entry.get("attack_period_ticks")) != TYPE_FLOAT
			or entry["attack_period_ticks"] < 1.0
			or typeof(entry.get("damage_min")) != TYPE_FLOAT
			or typeof(entry.get("damage_max")) != TYPE_FLOAT
			or entry["damage_min"] < 1.0
			or entry["damage_max"] < entry["damage_min"]
		):
			push_error("weapon_defs: %s has a malformed weapon %s" % [source, JSON.stringify(entry)])
			return {}
		periods[entry["id"]] = int(entry["attack_period_ticks"])
	return periods
