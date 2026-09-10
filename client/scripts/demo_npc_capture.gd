extends RefCounted


const NpcDummyScript := preload("res://scripts/npc_dummy.gd")


static func dump(session: Object) -> PackedStringArray:
	var lines := PackedStringArray()
	if session == null:
		return lines
	var npcs: Variant = session.get("_npcs")
	if typeof(npcs) != TYPE_DICTIONARY:
		return lines
	var bodies: Dictionary = npcs
	var ids: Array = bodies.keys()
	ids.sort()
	for id_variant: Variant in ids:
		var id := int(id_variant)
		var body: NpcDummyScript = bodies.get(id) as NpcDummyScript
		if body == null:
			continue
		var walking := 1 if body.is_walking() else 0
		var path_flag := 1 if body.has_path() else 0
		var npc_line := (
			"DEMO npc %d %s %f %f walking=%d has_path=%d"
			% [id, body.kind, body.position.x, body.position.z, walking, path_flag]
		)
		var clip := body.current_anim_clip()
		if clip.is_empty():
			clip = "none"
		var anim_line := "DEMO anim %d %s" % [id, clip]
		print(npc_line)
		print(anim_line)
		lines.append(npc_line)
		lines.append(anim_line)
	return lines
