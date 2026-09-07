extends RefCounted

## Never instantiated. Typed by [code]preload[/code]:
##
## [codeblock]
## const ClassDefs := preload("res://scripts/class_defs.gd")
## var defs := ClassDefs.load_default()
## [/codeblock]
##
## Reads the same shared tables as the Go server: shared/sets.json,
## shared/skills.json, and shared/classes.json. The client is cache-only, so
## every loader fails closed to an empty catalog rather than inventing content.

const SETS_REL_PATH := "shared/sets.json"
const SKILLS_REL_PATH := "shared/skills.json"
const CLASSES_REL_PATH := "shared/classes.json"

const HANDED_ONE := "one"
const HANDED_TWO := "two"


static func load_sets() -> Dictionary:
	var path := resolve_path(SETS_REL_PATH, "MARQUE_SETS")
	if path.is_empty():
		push_error("class_defs: %s not found (set MARQUE_SETS)" % SETS_REL_PATH)
		return _empty_for("by_set_id")
	return load_from_path(path, "sets", "by_set_id")


static func load_skills() -> Dictionary:
	var path := resolve_path(SKILLS_REL_PATH, "MARQUE_SKILLS")
	if path.is_empty():
		push_error("class_defs: %s not found (set MARQUE_SKILLS)" % SKILLS_REL_PATH)
		return _empty_for("by_skill_id")
	return load_from_path(path, "skills", "by_skill_id")


static func load_classes() -> Dictionary:
	var path := resolve_path(CLASSES_REL_PATH, "MARQUE_CLASSES")
	if path.is_empty():
		push_error("class_defs: %s not found (set MARQUE_CLASSES)" % CLASSES_REL_PATH)
		return _empty_for("by_class_id")
	return load_from_path(path, "classes", "by_class_id")


static func load_from_path(path: String, root_key: String, catalog_key: String) -> Dictionary:
	if path.is_empty():
		push_error("class_defs: empty path")
		return _empty_for(catalog_key)
	if not FileAccess.file_exists(path):
		push_error("class_defs: missing file %s" % path)
		return _empty_for(catalog_key)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error(
			"class_defs: could not open %s: %d" % [path, FileAccess.get_open_error()]
		)
		return _empty_for(catalog_key)
	var text := file.get_as_text()
	file.close()
	return parse_text(text, root_key, catalog_key, path)


static func parse_text(text: String, root_key: String, catalog_key: String, source: String = "<memory>") -> Dictionary:
	if text.strip_edges().is_empty():
		push_error("class_defs: empty file %s" % source)
		return _empty_for(catalog_key)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("class_defs: malformed JSON in %s" % source)
		return _empty_for(catalog_key)
	var root: Dictionary = parsed
	if not root.has(root_key) or typeof(root[root_key]) != TYPE_ARRAY:
		push_error("class_defs: %s missing %s array" % [source, root_key])
		return _empty_for(catalog_key)
	var list: Array = root[root_key]
	if list.is_empty():
		push_error("class_defs: %s has no %s" % [source, root_key])
		return _empty_for(catalog_key)
	var by_id := {}
	for i in list.size():
		var entry: Variant = list[i]
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("class_defs: %s %s[%d] is not an object" % [source, root_key, i])
			return _empty_for(catalog_key)
		var item: Dictionary = entry
		var err := _validate(item, root_key)
		if not err.is_empty():
			push_error("class_defs: %s %s[%d]: %s" % [source, root_key, i, err])
			return _empty_for(catalog_key)
		var id: String = item["id"]
		if by_id.has(id):
			push_error("class_defs: %s duplicate %s id %s" % [source, root_key, id])
			return _empty_for(catalog_key)
		by_id[id] = item
	return {catalog_key: by_id}


static func get_set(catalog: Dictionary, id: String) -> Variant:
	var by_id: Dictionary = catalog.get("by_set_id", {})
	if not by_id.has(id):
		return null
	return by_id[id]


static func get_skill(catalog: Dictionary, id: String) -> Variant:
	var by_id: Dictionary = catalog.get("by_skill_id", {})
	if not by_id.has(id):
		return null
	return by_id[id]


static func lookup_class(catalog: Dictionary, id: String) -> Variant:
	var by_id: Dictionary = catalog.get("by_class_id", {})
	if not by_id.has(id):
		return null
	return by_id[id]


static func class_display_name(catalog: Dictionary, id: String) -> String:
	if id.is_empty():
		return ""
	var entry: Variant = lookup_class(catalog, id)
	if entry == null:
		return id
	return String(entry["name"])


static func set_ids(catalog: Dictionary) -> PackedStringArray:
	var by_id: Dictionary = catalog.get("by_set_id", {})
	return PackedStringArray(by_id.keys())


static func skill_ids(catalog: Dictionary) -> PackedStringArray:
	var by_id: Dictionary = catalog.get("by_skill_id", {})
	return PackedStringArray(by_id.keys())


static func class_ids(catalog: Dictionary) -> PackedStringArray:
	var by_id: Dictionary = catalog.get("by_class_id", {})
	return PackedStringArray(by_id.keys())


static func resolve_path(rel: String, env_name: String) -> String:
	var env := OS.get_environment(env_name)
	if not env.is_empty():
		return env
	var start := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var dir := start
	while not dir.is_empty():
		var candidate := dir.path_join(rel)
		if FileAccess.file_exists(candidate):
			return candidate
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


static func _empty_for(catalog_key: String) -> Dictionary:
	return {catalog_key: {}}


static func _validate(item: Dictionary, root_key: String) -> String:
	var id: String = item.get("id", "")
	if id.is_empty():
		return "missing id"
	var name: Variant = item.get("name", null)
	if typeof(name) != TYPE_STRING or String(name).is_empty():
		return "%s: missing name" % id
	if root_key == "skills":
		var max_level: Variant = item.get("max_level", null)
		if not (typeof(max_level) == TYPE_INT or typeof(max_level) == TYPE_FLOAT) or float(max_level) < 1.0:
			return "%s: max_level must be a number >= 1" % id
		return ""
	if root_key == "classes":
		var skill: Variant = item.get("skill", null)
		if typeof(skill) != TYPE_STRING or String(skill).is_empty():
			return "%s: missing skill" % id
		var requires: Variant = item.get("requires", null)
		if typeof(requires) != TYPE_DICTIONARY:
			return "%s: requires required" % id
		var requires_dict: Dictionary = requires
		for slot in requires_dict:
			var kind: Variant = requires_dict[slot]
			if typeof(kind) != TYPE_STRING or String(kind).is_empty():
				return "%s: requires slot %s has no kind" % [id, slot]
		return ""
	var slots: Variant = item.get("slots", null)
	if typeof(slots) != TYPE_DICTIONARY:
		return "%s: slots required" % id
	var slots_dict: Dictionary = slots
	for slot in slots_dict:
		var kind: Variant = slots_dict[slot]
		if typeof(kind) != TYPE_STRING or String(kind).is_empty():
			return "%s: slot %s has no kind" % [id, slot]
	var tools: Variant = item.get("tools", null)
	if typeof(tools) != TYPE_DICTIONARY:
		return "%s: tools required" % id
	var tools_dict: Dictionary = tools
	for tool_kind in tools_dict:
		var entry: Variant = tools_dict[tool_kind]
		if typeof(entry) != TYPE_DICTIONARY:
			return "%s: tool %s is not an object" % [id, tool_kind]
		var tool: Dictionary = entry
		var handed := String(tool.get("handed", ""))
		if handed != HANDED_ONE and handed != HANDED_TWO:
			return "%s: unknown handed %s for tool %s" % [id, handed, tool_kind]
	return ""