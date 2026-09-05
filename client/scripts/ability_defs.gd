extends RefCounted

## Loads ability definitions from the shared JSON table.
##
## The only content source is [code]shared/abilities.json[/code] at the repo
## root (PROTOCOL.md, Abilities / M6a). This client does not invent fallback
## spells when the file is missing or malformed: [method load_from_path]
## returns an empty catalog and logs, and callers must treat that as no
## abilities.
##
## Never instantiated. Typed by [code]preload[/code]:
##
## [codeblock]
## const AbilityDefs := preload("res://scripts/ability_defs.gd")
## var cat := AbilityDefs.load_default()
## [/codeblock]

const REL_PATH := "shared/abilities.json"

const EFFECT_HEAL := "heal"
const EFFECT_DAMAGE := "damage"

const TARGET_FRIENDLY := "friendly"
const TARGET_HOSTILE := "hostile"
const TARGET_SELF := "self"


static func load_default() -> Dictionary:
	var path := resolve_path()
	if path.is_empty():
		push_error("ability_defs: %s not found (set MARQUE_ABILITIES)" % REL_PATH)
		return _empty_catalog()
	return load_from_path(path)


static func load_from_path(path: String) -> Dictionary:
	if path.is_empty():
		push_error("ability_defs: empty path")
		return _empty_catalog()
	if not FileAccess.file_exists(path):
		push_error("ability_defs: missing file %s" % path)
		return _empty_catalog()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error(
			"ability_defs: could not open %s: %d" % [path, FileAccess.get_open_error()]
		)
		return _empty_catalog()
	var text := file.get_as_text()
	file.close()
	return parse_text(text, path)


static func parse_text(text: String, source: String = "<memory>") -> Dictionary:
	if text.strip_edges().is_empty():
		push_error("ability_defs: empty file %s" % source)
		return _empty_catalog()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("ability_defs: malformed JSON in %s" % source)
		return _empty_catalog()
	var root: Dictionary = parsed
	if not root.has("abilities") or typeof(root["abilities"]) != TYPE_ARRAY:
		push_error("ability_defs: %s missing abilities array" % source)
		return _empty_catalog()
	var list: Array = root["abilities"]
	if list.is_empty():
		push_error("ability_defs: %s has no abilities" % source)
		return _empty_catalog()
	var by_id := {}
	for i in list.size():
		var entry: Variant = list[i]
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("ability_defs: %s abilities[%d] is not an object" % [source, i])
			return _empty_catalog()
		var ability: Dictionary = entry
		var err := _validate(ability)
		if not err.is_empty():
			push_error("ability_defs: %s abilities[%d]: %s" % [source, i, err])
			return _empty_catalog()
		var id: String = ability["id"]
		if by_id.has(id):
			push_error("ability_defs: %s duplicate id %s" % [source, id])
			return _empty_catalog()
		by_id[id] = ability
	return {"by_id": by_id}


static func get_ability(catalog: Dictionary, id: String) -> Variant:
	var by_id: Dictionary = catalog.get("by_id", {})
	if not by_id.has(id):
		return null
	return by_id[id]


static func ids(catalog: Dictionary) -> PackedStringArray:
	var by_id: Dictionary = catalog.get("by_id", {})
	return PackedStringArray(by_id.keys())


static func resolve_path() -> String:
	var env := OS.get_environment("MARQUE_ABILITIES")
	if not env.is_empty():
		return env
	var start := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var dir := start
	while not dir.is_empty():
		var candidate := dir.path_join(REL_PATH)
		if FileAccess.file_exists(candidate):
			return candidate
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


static func _empty_catalog() -> Dictionary:
	return {"by_id": {}}


static func _validate(ability: Dictionary) -> String:
	if typeof(ability.get("id", null)) != TYPE_STRING or String(ability["id"]).is_empty():
		return "missing id"
	var id: String = ability["id"]
	if typeof(ability.get("name", null)) != TYPE_STRING or String(ability["name"]).is_empty():
		return "%s: missing name" % id
	if not _is_number(ability.get("mana_cost", null)):
		return "%s: mana_cost required" % id
	if float(ability["mana_cost"]) < 0.0:
		return "%s: mana_cost must be >= 0" % id
	if not _is_number(ability.get("range", null)):
		return "%s: range required" % id
	if float(ability["range"]) < 0.0:
		return "%s: range must be >= 0" % id
	var target := String(ability.get("target", ""))
	if target != TARGET_FRIENDLY and target != TARGET_HOSTILE and target != TARGET_SELF:
		return "%s: unknown target %s" % [id, target]
	var effect: Variant = ability.get("effect", null)
	if typeof(effect) != TYPE_DICTIONARY:
		return "%s: effect required" % id
	var effect_dict: Dictionary = effect
	var kind := String(effect_dict.get("kind", ""))
	if kind != EFFECT_HEAL and kind != EFFECT_DAMAGE:
		return "%s: unknown effect.kind %s" % [id, kind]
	if not _is_number(effect_dict.get("amount", null)):
		return "%s: effect.amount required" % id
	var ui: Variant = ability.get("ui", null)
	if typeof(ui) != TYPE_DICTIONARY:
		return "%s: ui required" % id
	var ui_dict: Dictionary = ui
	if typeof(ui_dict.get("color", null)) != TYPE_STRING or String(ui_dict["color"]).is_empty():
		return "%s: ui.color required" % id
	return ""


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
