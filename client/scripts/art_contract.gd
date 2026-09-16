extends RefCounted


const PATH := "res://assets/proto/art_contract.json"
const VERSION := 1
const FALLBACK_KEY := ""
const PROP_STATES: PackedStringArray = ["", "full", "depleted"]


class Bone:
	extends RefCounted
	var name := ""
	var parent := ""
	var head := Vector3.ZERO
	var tail := Vector3.ZERO
	var roll := 0.0


class Variant:
	extends RefCounted
	var name := ""
	var scale := 0.0
	var glb := ""


class Piece:
	extends RefCounted
	var item := ""
	var slot := ""
	var hides := PackedStringArray()


class Clip:
	extends RefCounted
	var name := ""
	var frames := 0
	var loop := false


var errors := PackedStringArray()
var fps := 0
var armature := ""
var rest_source := ""
var clips_glb := ""
var clip_rig := ""
var bones: Array[Bone] = []
var variants := {}
var regions := {}
var slot_regions := {}
var pieces := {}
var hand_items := {}
var props := {}
var clips := {}
var _routes := {}


static func read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error(
			"art_contract: could not open %s: %s"
			% [path, error_string(FileAccess.get_open_error())]
		)
		return ""
	return file.get_as_text()


func _init(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("contract is not a JSON object")
		return
	var root: Dictionary = parsed
	if _number(root, "version", "contract") != VERSION:
		_fail("contract version must be %d" % VERSION)
	fps = _positive_int(root, "fps", "contract")
	armature = _string(root, "armature", "contract")
	rest_source = _res_path(root, "rest_source", "contract")
	clips_glb = _res_path(root, "clips_glb", "contract")
	_parse_bones(_array(root, "bones", "contract"))
	_parse_variants(_object(root, "variants", "contract"))
	clip_rig = _string(root, "clip_rig", "contract")
	if not variants.has(clip_rig):
		_fail("clip_rig %s is not a declared variant" % clip_rig)
	_parse_regions(_object(root, "regions", "contract"))
	_parse_slot_regions(_object(root, "slot_regions", "contract"))
	_parse_pieces(_object(root, "pieces", "contract"))
	var items := _object(root, "hand_items", "contract")
	for item in items:
		hand_items[item] = _res_path(items, item, "hand_items")
	_parse_props(_object(root, "props", "contract"))
	_parse_clips(_object(root, "clips", "contract"))
	_parse_routes(_array(root, "routes", "contract"))


func is_valid() -> bool:
	return errors.is_empty()


func bone_names() -> PackedStringArray:
	var names := PackedStringArray()
	for bone in bones:
		names.append(bone.name)
	return names


func actions() -> PackedStringArray:
	return PackedStringArray(_routes.keys())


func clip_for(action: String, key: String) -> String:
	if not _routes.has(action):
		push_error("art_contract: no route for action %s" % action)
		return ""
	var by_key: Dictionary = _routes[action]
	return by_key.get(key, by_key[FALLBACK_KEY])


func clip_length(clip: String) -> float:
	return float(clips[clip].frames) / fps


func motion_scale(variant: String) -> float:
	return variants[variant].scale / variants[clip_rig].scale


func prop_for(kind: String, state: String) -> String:
	var by_state: Dictionary = props.get(kind, {})
	var glb: String = by_state.get(state, by_state.get(FALLBACK_KEY, ""))
	if glb.is_empty():
		push_error('art_contract: no prop for kind %s in state "%s"' % [kind, state])
	return glb


func _parse_bones(rows: Array) -> void:
	var declared := {}
	for index in rows.size():
		var row := _entry(rows[index], "bones[%d]" % index)
		var bone := Bone.new()
		bone.name = _string(row, "name", "bones[%d]" % index)
		var where := "bone %s" % bone.name
		if declared.has(bone.name):
			_fail("%s is declared twice" % where)
		if not row.has("parent"):
			_fail("%s is missing parent" % where)
		elif row["parent"] == null:
			if index != 0:
				_fail("%s has no parent; only the first bone is the root" % where)
		elif typeof(row["parent"]) != TYPE_STRING:
			_fail("%s parent must be a string or null" % where)
		else:
			bone.parent = row["parent"]
			if index == 0:
				_fail("%s is the first bone, so it must be the parentless root" % where)
			elif not declared.has(bone.parent):
				_fail("%s names parent %s before it is declared" % [where, bone.parent])
		bone.head = _vector3(row, "head", where)
		bone.tail = _vector3(row, "tail", where)
		bone.roll = _number(row, "roll", where)
		if bone.head.is_equal_approx(bone.tail):
			_fail("%s has zero length" % where)
		declared[bone.name] = true
		bones.append(bone)


func _parse_variants(rows: Dictionary) -> void:
	for name in rows:
		var row := _entry(rows[name], "variant %s" % name)
		var variant := Variant.new()
		variant.name = name
		variant.scale = _number(row, "scale", "variant %s" % name)
		if variant.scale <= 0.0:
			_fail("variant %s scale must be positive" % name)
		variant.glb = _res_path(row, "glb", "variant %s" % name)
		variants[name] = variant


func _parse_regions(rows: Dictionary) -> void:
	var owner := {}
	var known := bone_names()
	for region in rows:
		var members := _names(rows[region], "region %s" % region)
		for bone in members:
			if not known.has(bone):
				_fail("region %s names unknown bone %s" % [region, bone])
			elif owner.has(bone):
				_fail("bone %s is in regions %s and %s" % [bone, owner[bone], region])
			else:
				owner[bone] = region
		regions[region] = members
	for bone in bones:
		if bone.parent.is_empty() and owner.has(bone.name):
			_fail("root bone %s must not belong to a region" % bone.name)
		elif not bone.parent.is_empty() and not owner.has(bone.name):
			_fail("bone %s belongs to no region" % bone.name)


func _parse_slot_regions(rows: Dictionary) -> void:
	var owner := {}
	for slot in rows:
		var members := _names(rows[slot], "slot %s" % slot)
		for region in members:
			if not regions.has(region):
				_fail("slot %s owns unknown region %s" % [slot, region])
			elif owner.has(region):
				_fail("region %s is owned by slots %s and %s" % [region, owner[region], slot])
			else:
				owner[region] = slot
		slot_regions[slot] = members


func _parse_pieces(rows: Dictionary) -> void:
	for item in rows:
		var where := "piece %s" % item
		var row := _entry(rows[item], where)
		var piece := Piece.new()
		piece.item = item
		piece.slot = _string(row, "slot", where)
		piece.hides = _names(row.get("hides"), "%s hides" % where)
		if not slot_regions.has(piece.slot):
			_fail("%s names unknown slot %s" % [where, piece.slot])
		else:
			var owned: PackedStringArray = slot_regions[piece.slot]
			for region in piece.hides:
				if not owned.has(region):
					_fail("%s hides region %s outside slot %s" % [where, region, piece.slot])
		pieces[item] = piece


func _parse_clips(rows: Dictionary) -> void:
	for name in rows:
		var row := _entry(rows[name], "clip %s" % name)
		var clip := Clip.new()
		clip.name = name
		clip.frames = _positive_int(row, "frames", "clip %s" % name)
		clip.loop = _value(row, "loop", TYPE_BOOL, "clip %s" % name) == true
		clips[name] = clip


func _parse_routes(rows: Array) -> void:
	var routed := {}
	for index in rows.size():
		var row := _entry(rows[index], "routes[%d]" % index)
		var action := _string(row, "action", "routes[%d]" % index)
		var key := _string(row, "key", "routes[%d]" % index)
		var clip := _string(row, "clip", "routes[%d]" % index)
		if action.is_empty():
			_fail("routes[%d] has an empty action" % index)
		if not clips.has(clip):
			_fail('route %s/"%s" names unknown clip %s' % [action, key, clip])
		var by_key: Dictionary = _routes.get_or_add(action, {})
		if by_key.has(key):
			_fail('route %s/"%s" is declared twice' % [action, key])
		by_key[key] = clip
		routed[clip] = true
	for action in _routes:
		if not _routes[action].has(FALLBACK_KEY):
			_fail('action %s has no fallback route with key ""' % action)
	for clip in clips:
		if not routed.has(clip):
			_fail("clip %s is not routed by any action" % clip)


func _parse_props(rows: Dictionary) -> void:
	for kind in rows:
		var where := "prop %s" % kind
		var states := _entry(rows[kind], where)
		for state in states:
			if not PROP_STATES.has(state):
				_fail('%s names unknown state "%s"' % [where, state])
			_res_path(states, state, where)
		if not states.has(FALLBACK_KEY) and not (states.has("full") and states.has("depleted")):
			_fail('%s needs a "" row or both full and depleted rows' % where)
		props[kind] = states


func _fail(message: String) -> void:
	errors.append(message)


func _value(row: Dictionary, key: String, type: Variant.Type, where: String) -> Variant:
	if not row.has(key):
		_fail("%s is missing %s" % [where, key])
		return null
	if typeof(row[key]) != type:
		_fail("%s %s must be a %s, got %s" % [where, key, type_string(type), JSON.stringify(row[key])])
		return null
	return row[key]


func _string(row: Dictionary, key: String, where: String) -> String:
	var value: Variant = _value(row, key, TYPE_STRING, where)
	return value if value != null else ""


func _res_path(row: Dictionary, key: String, where: String) -> String:
	var value := _string(row, key, where)
	if not value.begins_with("res://"):
		_fail("%s %s must be a res:// path, got %s" % [where, key, value])
	return value


func _number(row: Dictionary, key: String, where: String) -> float:
	var value: Variant = _value(row, key, TYPE_FLOAT, where)
	return value if value != null else 0.0


func _positive_int(row: Dictionary, key: String, where: String) -> int:
	var value := _number(row, key, where)
	if value < 1.0 or value != floorf(value):
		_fail("%s %s must be a positive integer, got %s" % [where, key, value])
		return 0
	return int(value)


func _array(row: Dictionary, key: String, where: String) -> Array:
	var value: Variant = _value(row, key, TYPE_ARRAY, where)
	return value if value != null else []


func _object(row: Dictionary, key: String, where: String) -> Dictionary:
	var value: Variant = _value(row, key, TYPE_DICTIONARY, where)
	return value if value != null else {}


func _entry(value: Variant, where: String) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		_fail("%s must be an object" % where)
		return {}
	return value


func _vector3(row: Dictionary, key: String, where: String) -> Vector3:
	var items := _array(row, key, where)
	if items.size() != 3 or items.any(func(item): return typeof(item) != TYPE_FLOAT):
		_fail("%s %s must be three numbers, got %s" % [where, key, JSON.stringify(items)])
		return Vector3.ZERO
	return Vector3(items[0], items[1], items[2])


func _names(value: Variant, where: String) -> PackedStringArray:
	if typeof(value) != TYPE_ARRAY or (value as Array).any(func(item): return typeof(item) != TYPE_STRING):
		_fail("%s must be an array of names" % where)
		return PackedStringArray()
	return PackedStringArray(value)
