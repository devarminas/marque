extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const NpcDummyScene := preload("res://scenes/npc_dummy.tscn")
const NpcQuestGiverScene := preload("res://scenes/npc_quest_giver.tscn")
const NpcImpScene := preload("res://scenes/npc_imp.tscn")
const DemoNpcCapture := preload("res://scripts/demo_npc_capture.gd")
const Assertions := preload("res://tests/assertions.gd")

const QUEST_GIVER_BODY_SKIN := "Superhero_Female"
const IMP_BODY_SKIN := "Imp_Body"
const PLAYER_HEIGHT_BAND_MIN := 1.6
const PLAYER_HEIGHT_BAND_MAX := 1.8
const MAGENTA := Color(0.95, 0.08, 0.85, 1)

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _casts: Array = []
var _attacks: PackedInt32Array = PackedInt32Array()
var _attack_refuses: Array = []


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== npcs: welcome, select, cast faction targets, attack refuse ==")

	_test_quest_giver_scene_is_female_rig()
	_test_dummy_scene_stays_capsule()
	_test_imp_scene_uses_bestiary_mesh()
	_test_imp_authors_animation_player()
	_test_mobile_npc_without_animation_player_reports_once()
	_test_imp_missing_body_draws_magenta()

	_root = MainScene.instantiate() as Node3D
	_root.name = "NpcClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_session.cast_requested.connect(
		func(ability_id: String, target_id: int) -> void:
			_casts.append({"ability": ability_id, "player": target_id})
	)
	_session.attack_requested.connect(func(id: int) -> void: _attacks.append(id))
	_session.attack_refused.connect(
		func(id: int, reason: String) -> void:
			_attack_refuses.append({"player": id, "reason": reason})
	)

	await get_tree().process_frame
	await get_tree().process_frame

	_feed_welcome_with_npcs()
	await get_tree().process_frame
	await get_tree().process_frame

	_test_bodies_and_select()
	_test_quest_giver_spawns_from_welcome()
	_test_imp_spawns_from_welcome()
	_test_imp_follows_path_frames()
	_test_demo_npc_capture_dump()
	_test_cast_targets()
	_test_attack_targets()
	_test_despawn_forgets_npc()
	_test_npc_spawn_after_despawn()

	_finished = true


func _test_quest_giver_scene_is_female_rig() -> void:
	var giver := NpcQuestGiverScene.instantiate() as NpcDummyScript
	_check(giver != null, "npc_quest_giver.tscn instantiates as NpcDummy")
	if giver == null:
		return
	_world.add_child(giver)
	var skeleton := giver.get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
	_check(skeleton != null, "quest giver Body/Armature/Skeleton3D exists")
	var skin_names := PackedStringArray()
	if skeleton != null:
		for node in skeleton.get_children():
			if node is MeshInstance3D:
				skin_names.append(String(node.name))
	_check(
		skin_names.has(QUEST_GIVER_BODY_SKIN),
		"quest giver skins include %s, got [%s]" % [QUEST_GIVER_BODY_SKIN, ", ".join(skin_names)],
	)
	_check(not (giver.get_node("Body") is MeshInstance3D), "quest giver Body is not a capsule mesh")
	giver.queue_free()


func _test_dummy_scene_stays_capsule() -> void:
	var dummy := NpcDummyScene.instantiate() as NpcDummyScript
	_check(dummy != null, "npc_dummy.tscn instantiates as NpcDummy")
	if dummy == null:
		return
	_world.add_child(dummy)
	_check(dummy.get_node("Body") is MeshInstance3D, "practice dummy Body stays a MeshInstance3D capsule")
	_check(
		dummy.get_node_or_null("Body/Armature/Skeleton3D") == null,
		"practice dummy has no female Armature",
	)
	_check(dummy.static_mesh, "practice dummy is flagged static_mesh (no AnimationPlayer required)")
	dummy.queue_free()


func _test_imp_scene_uses_bestiary_mesh() -> void:
	var imp := NpcImpScene.instantiate() as NpcDummyScript
	_check(imp != null, "npc_imp.tscn instantiates as NpcDummy")
	if imp == null:
		return
	_world.add_child(imp)
	var skeleton := imp.get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
	_check(skeleton != null, "imp Body/Armature/Skeleton3D exists")
	var skin_names := PackedStringArray()
	if skeleton != null:
		for node in skeleton.get_children():
			if node is MeshInstance3D:
				skin_names.append(String(node.name))
	_check(
		skin_names.has(IMP_BODY_SKIN),
		"imp skins include %s, got [%s]" % [IMP_BODY_SKIN, ", ".join(skin_names)],
	)
	_check(not (imp.get_node("Body") is MeshInstance3D), "imp Body is not a capsule mesh")
	var missing := imp.get_node_or_null("MissingBody") as MeshInstance3D
	_check(missing != null and not missing.visible, "healthy imp keeps magenta fallback hidden")
	var body_mesh := imp.get_node_or_null("Body/Armature/Skeleton3D/Imp_Body") as MeshInstance3D
	_check(body_mesh != null, "Imp_Body mesh instance exists")
	if body_mesh != null:
		var height := body_mesh.get_aabb().size.y
		_check(
			height >= PLAYER_HEIGHT_BAND_MIN and height <= PLAYER_HEIGHT_BAND_MAX,
			"imp mesh height sits in the ~1.7u player band, got %f" % height,
		)
	imp.queue_free()


func _test_imp_authors_animation_player() -> void:
	var imp := NpcImpScene.instantiate() as NpcDummyScript
	_check(imp != null, "imp AnimationPlayer check instantiates npc_imp")
	if imp == null:
		return
	_world.add_child(imp)
	_check(not imp.static_mesh, "imp is a mobile NPC (static_mesh off)")
	var animation := imp.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_check(animation != null, "npc_imp.tscn authors an AnimationPlayer")
	_check(
		imp.get("_animation") == animation,
		"imp _ready binds the authored AnimationPlayer",
	)
	imp.call("_set_walking", true)
	_check(
		not imp.get("_missing_animation_reported"),
		"imp with AnimationPlayer does not take the missing-player loud path",
	)
	imp.queue_free()


func _test_mobile_npc_without_animation_player_reports_once() -> void:
	var body := NpcDummyScript.new()
	body.name = "SabotagedMobile"
	body.kind = NpcDummyScript.KindImp
	body.static_mesh = false
	_world.add_child(body)
	_check(body.get_node_or_null("AnimationPlayer") == null, "sabotage body has no AnimationPlayer")
	_check(not body.get("_missing_animation_reported"), "loud path starts unset")
	body.call("_set_walking", true)
	_check(
		body.get("_missing_animation_reported"),
		"mobile NPC without AnimationPlayer latches the loud missing-player path",
	)
	body.call("_set_walking", true)
	_check(
		body.get("_missing_animation_reported"),
		"a second _set_walking keeps the missing-player latch set",
	)
	body.queue_free()


func _test_imp_missing_body_draws_magenta() -> void:
	var imp := NpcImpScene.instantiate() as NpcDummyScript
	_check(imp != null, "magenta check instantiates npc_imp")
	if imp == null:
		return
	var body := imp.get_node("Body")
	imp.remove_child(body)
	body.queue_free()
	_world.add_child(imp)
	var fallback := imp.get_node_or_null("MissingBody") as MeshInstance3D
	_check(fallback != null and fallback.visible, "a vanished imp body shows the magenta fallback")
	var material := fallback.get_active_material(0) if fallback != null else null
	var albedo := Color(0.0, 0.0, 0.0, 0.0)
	if material != null and "albedo_color" in material:
		albedo = material.albedo_color
	_check(
		is_equal_approx(albedo.r, MAGENTA.r)
		and is_equal_approx(albedo.g, MAGENTA.g)
		and is_equal_approx(albedo.b, MAGENTA.b)
		and is_equal_approx(albedo.a, MAGENTA.a),
		"the imp fallback is the palette magenta, got %s" % albedo,
	)
	imp.queue_free()


func _feed_welcome_with_npcs() -> void:
	_net.ingest_text_frame(
		'{"welcome":{"you":3,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":3,"x":0.0,"z":0.0,"hp":100,"max_hp":100,"mana":100,"max_mana":100}],'
		+ '"items":[],"nodes":[],'
		+ '"npcs":['
		+ '{"id":1000001,"kind":"dummy","faction":"friendly","x":-3.0,"z":0.0,"hp":100,"max_hp":100},'
		+ '{"id":1000002,"kind":"dummy","faction":"hostile","x":3.0,"z":0.0,"hp":100,"max_hp":100},'
		+ '{"id":1000003,"kind":"quest_giver","faction":"friendly","x":0.0,"z":-3.0,"hp":100,"max_hp":100},'
		+ '{"id":1000004,"kind":"imp","faction":"hostile","x":12.0,"z":8.0,"hp":50,"max_hp":50}'
		+ "]}}"
	)


func _test_bodies_and_select() -> void:
	var npcs: Dictionary = _session.get("_npcs")
	_check(npcs.size() == 4, "session registry holds four npcs")
	var friendly: NpcDummyScript = npcs.get(1000001)
	var hostile: NpcDummyScript = npcs.get(1000002)
	_check(friendly != null and hostile != null, "both dummy bodies exist")
	if friendly == null or hostile == null:
		return
	_check(friendly.faction == "friendly", "id 1000001 is friendly")
	_check(hostile.faction == "hostile", "id 1000002 is hostile")
	_check(_session.select_player(1000001), "select friendly dummy")
	_check(_session.selected_player_id() == 1000001, "selection is friendly")
	_check(friendly.is_selected(), "friendly chrome on")
	_check(not hostile.is_selected(), "hostile chrome off")
	_check(_session.select_player(1000002), "select hostile dummy")
	_check(_session.selected_player_id() == 1000002, "selection is hostile")
	_check(hostile.is_selected(), "hostile chrome on")
	_check(not friendly.is_selected(), "friendly chrome off")


func _test_quest_giver_spawns_from_welcome() -> void:
	var npcs: Dictionary = _session.get("_npcs")
	var giver: NpcDummyScript = npcs.get(1000003)
	_check(giver != null, "quest giver body exists from welcome")
	if giver == null:
		return
	_check(giver.kind == NpcDummyScript.KindQuestGiver, "id 1000003 kind is quest_giver")
	_check(
		giver.get_node_or_null("Body/Armature/Skeleton3D") != null,
		"welcome quest giver uses the female rig scene",
	)
	_check(not (giver.get_node("Body") is MeshInstance3D), "welcome quest giver is not a capsule")


func _test_imp_spawns_from_welcome() -> void:
	var npcs: Dictionary = _session.get("_npcs")
	var imp: NpcDummyScript = npcs.get(1000004)
	_check(imp != null, "imp body exists from welcome")
	if imp == null:
		return
	_check(imp.kind == NpcDummyScript.KindImp, "id 1000004 kind is imp")
	_check(imp.faction == NpcDummyScript.FactionHostile, "welcome imp is hostile")
	_check(
		imp.get_node_or_null("Body/Armature/Skeleton3D") != null,
		"welcome imp uses the bestiary Imp scene",
	)
	_check(not (imp.get_node("Body") is MeshInstance3D), "welcome imp is not a capsule")
	_check(
		imp.get_node_or_null("MissingBody") != null and not imp.get_node("MissingBody").visible,
		"welcome imp hides magenta",
	)


func _test_imp_follows_path_frames() -> void:
	var npcs: Dictionary = _session.get("_npcs")
	var imp: NpcDummyScript = npcs.get(1000004)
	_check(imp != null, "imp exists before path frame")
	if imp == null:
		return
	_check(
		is_equal_approx(imp.position.x, 12.0) and is_equal_approx(imp.position.z, 8.0),
		"imp still at welcome camp before path, got %s" % imp.position,
	)
	_net.ingest_text_frame(
		'{"path":{"id":1000004,"start_tick":1,"speed":3.0,"points":[[12.0,8.0],[0.0,0.0]]}}'
	)
	_check(imp.has_path(), "imp has_path after path frame")
	imp.update_to_tick(1)
	_check(imp.is_walking(), "imp is_walking at path start_tick")
	_check(
		is_equal_approx(imp.position.x, 12.0) and is_equal_approx(imp.position.z, 8.0),
		"imp at path start on start_tick, got %s" % imp.position,
	)
	# 3 u/s * 150ms = 0.45u per tick; 10 ticks ≈ 4.5u toward origin from (12,8).
	imp.update_to_tick(11)
	_check(imp.is_walking(), "imp still walking mid-path at tick 11")
	var moved := Vector2(imp.position.x, imp.position.z).distance_to(Vector2(12.0, 8.0))
	_check(moved >= 3.0, "imp mesh advanced ≥3u along path by tick 11, moved=%.3f at %s" % [moved, imp.position])
	_check(
		Vector2(imp.position.x, imp.position.z).distance_to(Vector2.ZERO)
		< Vector2(12.0, 8.0).distance_to(Vector2.ZERO),
		"imp closer to player origin than camp after chase path",
	)


func _test_demo_npc_capture_dump() -> void:
	var npcs: Dictionary = _session.get("_npcs")
	_check(not npcs.is_empty(), "session has npcs before capture dump")
	var imp: NpcDummyScript = npcs.get(1000004)
	_check(imp != null and imp.has_path(), "imp still has_path for capture dump")
	_check(not imp.current_anim_clip().is_empty(), "current_anim_clip returns a string")
	var lines := DemoNpcCapture.dump(_session)
	_check(lines.size() >= 2, "demo_npc_capture.dump emits npc+anim lines, got %d" % lines.size())
	var saw_imp_npc := false
	var saw_imp_anim := false
	for line: String in lines:
		if line.begins_with("DEMO npc 1000004 ") and line.contains("walking=1") and line.contains("has_path=1"):
			saw_imp_npc = true
		if line.begins_with("DEMO anim 1000004 "):
			saw_imp_anim = true
	_check(saw_imp_npc, "capture dump includes walking imp DEMO npc line")
	_check(saw_imp_anim, "capture dump includes DEMO anim for imp")


func _test_cast_targets() -> void:
	_casts.clear()
	_session.select_player(1000001)
	_session.request_cast("heal")
	_check(_casts.size() == 1, "heal emits one cast")
	if _casts.size() == 1:
		_check(_casts[0]["player"] == 1000001, "heal targets friendly selection")

	_casts.clear()
	_session.select_player(1000002)
	_session.request_cast("heal")
	_check(_casts.size() == 1, "heal with hostile selection still emits")
	if _casts.size() == 1:
		_check(_casts[0]["player"] == 3, "heal falls back to self on hostile selection")

	_casts.clear()
	_session.select_player(1000002)
	_session.request_cast("fireball")
	_check(_casts.size() == 1, "fireball emits one cast")
	if _casts.size() == 1:
		_check(_casts[0]["player"] == 1000002, "fireball targets hostile selection")


func _test_attack_targets() -> void:
	_attacks.clear()
	_attack_refuses.clear()
	_session.request_attack(1000001)
	_check(_attacks.is_empty(), "friendly dummy never becomes an attack intent")
	_check(
		_attack_refuses.size() == 1
		and _attack_refuses[0]["player"] == 1000001
		and _attack_refuses[0]["reason"] == "wrong_target",
		"friendly refuse emits attack_refused wrong_target, got %s" % [_attack_refuses],
	)

	_attacks.clear()
	_attack_refuses.clear()
	_session.request_attack(1000002)
	_check(
		_attacks.size() == 1 and _attacks[0] == 1000002,
		"hostile dummy becomes one attack naming 1000002, got %s" % [_attacks],
	)
	_check(_attack_refuses.is_empty(), "hostile dummy does not refuse")

	_attacks.clear()
	_attack_refuses.clear()
	_session.request_attack(1000004)
	_check(
		_attacks.size() == 1 and _attacks[0] == 1000004,
		"hostile imp becomes one attack naming 1000004, got %s" % [_attacks],
	)
	_check(_attack_refuses.is_empty(), "hostile imp does not refuse")


func _test_despawn_forgets_npc() -> void:
	var npcs: Dictionary = _session.get("_npcs")
	_check(npcs.has(1000004), "imp is registered before despawn")
	_session.select_player(1000004)
	_check(_session.selected_player_id() == 1000004, "imp selected before despawn")
	_net.ingest_text_frame('{"despawn":{"id":1000004}}')
	npcs = _session.get("_npcs")
	_check(not npcs.has(1000004), "despawn forgets the npc registry entry")
	_check(_session.selected_player_id() == 0, "despawn clears selection of that npc")


func _test_npc_spawn_after_despawn() -> void:
	var npcs: Dictionary = _session.get("_npcs")
	_check(not npcs.has(1000006), "respawn id is absent before npc_spawn")
	_net.ingest_text_frame(
		'{"npc_spawn":{"id":1000006,"kind":"imp","faction":"hostile","x":13.0,"z":7.5,"hp":50,"max_hp":50}}'
	)
	npcs = _session.get("_npcs")
	var imp: NpcDummyScript = npcs.get(1000006)
	_check(imp != null, "npc_spawn builds an imp body")
	if imp == null:
		return
	_check(imp.kind == NpcDummyScript.KindImp, "npc_spawn kind is imp")
	_check(imp.faction == NpcDummyScript.FactionHostile, "npc_spawn faction is hostile")
	_check(
		imp.get_node_or_null("Body/Armature/Skeleton3D") != null,
		"npc_spawn imp uses the bestiary Imp scene",
	)
	_check(is_equal_approx(imp.global_position.x, 13.0), "npc_spawn places x")
	_check(is_equal_approx(imp.global_position.z, 7.5), "npc_spawn places z")
	var hp_map: Dictionary = _session.get("_hp")
	var hit: Variant = hp_map.get(1000006)
	_check(hit is Vector2i and hit == Vector2i(50, 50), "npc_spawn applies hit points")
	var label := imp.get_node_or_null("HpLabel") as Label3D
	_check(label != null and label.visible and label.text == "50/50", "npc_spawn shows hp label")


func _check(cond: bool, msg: String) -> void:
	_assertions.check(cond, msg)