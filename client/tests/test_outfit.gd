extends Node3D


const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")
const OutfitDefs := preload("res://scripts/outfit_defs.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const Assertions := preload("res://tests/assertions.gd")

const TICK_MS := 100
const PART_COUNT := 10
const TINT_SEPARATION := 0.05
const CLOTH_MATERIAL := "MI_Peasant"
const SKIN_MATERIAL := "MI_Regular_Male"
const CLOTH_PART := "PeasantBody"
const SKIN_PART := "PeasantArms"

@onready var _avatars: Node3D = $Avatars
@onready var _world: Node3D = $World

var _assertions: Assertions = null
var _finished := false


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures if _assertions != null else PackedStringArray()


func get_assertion_count() -> int:
	return _assertions.assertion_count if _assertions != null else 0


func _ready() -> void:
	_assertions = Assertions.new()

	_test_the_table_covers_every_server_class()
	_test_the_tints_stay_apart()
	_test_a_fresh_avatar_is_bare()
	_test_a_peasant_class_wears_only_the_peasant_parts()
	_test_a_ranger_class_wears_only_the_ranger_parts()
	_test_switching_class_swaps_the_whole_outfit()
	_test_an_unknown_class_returns_the_avatar_to_bare()
	_test_worn_parts_deform_with_the_base_rig()
	_test_the_tint_lands_on_cloth_and_spares_bare_skin()
	_test_one_class_shares_one_tinted_material()
	_test_two_avatars_of_different_classes_do_not_share_state()
	await _test_a_class_frame_dresses_the_local_avatar()

	_finished = true


func _test_the_table_covers_every_server_class() -> void:
	var server_ids := ClassDefs.class_ids(ClassDefs.load_classes())
	server_ids.sort()
	var table_ids := PackedStringArray(OutfitDefs.BY_CLASS.keys())
	table_ids.sort()
	_assertions.check(
		server_ids.size() > 0, "shared/classes.json resolved through class_defs.gd"
	)
	_assertions.check(
		server_ids == table_ids,
		"BY_CLASS dresses exactly the server's classes; classes.json has [%s], the table has [%s]"
		% [", ".join(server_ids), ", ".join(table_ids)],
	)
	for class_id: String in server_ids:
		_assertions.check(
			not OutfitDefs.outfit_for(class_id).is_empty(),
			"%s resolves to an outfit rather than staying bare" % class_id,
		)
		_assertions.check(
			OutfitDefs.parts_for(class_id).size() > 0,
			"%s names the parts it wears" % class_id,
		)

	var names := OutfitDefs.part_names()
	_assertions.check(
		names.size() == PART_COUNT,
		"part_names() lists all %d authored parts, got %d" % [PART_COUNT, names.size()],
	)
	var seen := {}
	for part_name: String in names:
		seen[part_name] = true
	_assertions.check(
		seen.size() == names.size(), "no part name is listed twice across the two outfits"
	)
	_assertions.check(
		names == OutfitDefs.part_names(),
		"part_names() returns the same order on every call, so callers can iterate it",
	)


func _test_the_tints_stay_apart() -> void:
	var ids := PackedStringArray(OutfitDefs.BY_CLASS.keys())
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			var first := OutfitDefs.tint_for(ids[a])
			var second := OutfitDefs.tint_for(ids[b])
			var apart := Vector3(
				first.r - second.r, first.g - second.g, first.b - second.b
			).length()
			_assertions.check(
				apart >= TINT_SEPARATION,
				"%s and %s are separable in a screenshot (%.3f apart, floor %.3f)"
				% [ids[a], ids[b], apart, TINT_SEPARATION],
			)
	_assertions.check(
		OutfitDefs.tint_for("") == Color.WHITE
		and OutfitDefs.tint_for("no_such_class") == Color.WHITE,
		"an empty or unknown class tints nothing",
	)


func _test_a_fresh_avatar_is_bare() -> void:
	var avatar := _spawn(1)

	_assertions.check(
		avatar.worn_outfit() == "",
		'a freshly instanced avatar reports no outfit, got "%s"' % avatar.worn_outfit(),
	)
	_assertions.check(
		_shown_parts(avatar).is_empty(),
		"all %d outfit parts start hidden, got [%s] shown"
		% [PART_COUNT, ", ".join(_shown_parts(avatar))],
	)
	_assertions.check(
		_body_scale(avatar) == Vector3.ONE,
		"an undressed body keeps its authored girth, got %s" % _body_scale(avatar),
	)
	_assertions.check(
		_parts(avatar).size() == PART_COUNT,
		"player_avatar.tscn authors all %d parts under Outfit, got %d"
		% [PART_COUNT, _parts(avatar).size()],
	)

	avatar.queue_free()


func _test_a_peasant_class_wears_only_the_peasant_parts() -> void:
	var avatar := _spawn(2)
	avatar.apply_class("lumberjack")

	_assertions.check(
		avatar.worn_outfit() == OutfitDefs.PEASANT,
		'lumberjack wears the peasant outfit, got "%s"' % avatar.worn_outfit(),
	)
	_assertions.check(
		_shown_parts(avatar) == OutfitDefs.parts_of(OutfitDefs.PEASANT),
		"lumberjack shows exactly the four peasant parts, got [%s]"
		% ", ".join(_shown_parts(avatar)),
	)
	for part_name: String in OutfitDefs.parts_of(OutfitDefs.RANGER):
		_assertions.check(
			not _part(avatar, part_name).visible,
			"lumberjack leaves the ranger part %s hidden" % part_name,
		)
	_assertions.check(
		_body_scale(avatar) == Vector3(OutfitDefs.DRESSED_GIRTH, 1.0, OutfitDefs.DRESSED_GIRTH),
		"a dressed body narrows to girth %.2f, got %s"
		% [OutfitDefs.DRESSED_GIRTH, _body_scale(avatar)],
	)
	_assertions.check(
		_body_scale(avatar).y == 1.0,
		"the dressed body keeps y scale exactly 1.0, so the head keeps its height, got %f"
		% _body_scale(avatar).y,
	)

	avatar.apply_class("lumberjack")
	_assertions.check(
		_shown_parts(avatar) == OutfitDefs.parts_of(OutfitDefs.PEASANT)
		and _body_scale(avatar) == Vector3(OutfitDefs.DRESSED_GIRTH, 1.0, OutfitDefs.DRESSED_GIRTH),
		"re-applying the same class is idempotent rather than compounding the girth",
	)

	avatar.queue_free()


func _test_a_ranger_class_wears_only_the_ranger_parts() -> void:
	var avatar := _spawn(3)
	avatar.apply_class("archer")

	_assertions.check(
		avatar.worn_outfit() == OutfitDefs.RANGER,
		'archer wears the ranger outfit, got "%s"' % avatar.worn_outfit(),
	)
	_assertions.check(
		_shown_parts(avatar) == OutfitDefs.parts_of(OutfitDefs.RANGER),
		"archer shows exactly the six ranger parts, got [%s]" % ", ".join(_shown_parts(avatar)),
	)
	for part_name: String in OutfitDefs.parts_of(OutfitDefs.PEASANT):
		_assertions.check(
			not _part(avatar, part_name).visible,
			"archer leaves the peasant part %s hidden" % part_name,
		)

	avatar.queue_free()


func _test_switching_class_swaps_the_whole_outfit() -> void:
	var avatar := _spawn(4)

	avatar.apply_class("archer")
	avatar.apply_class("mage")
	_assertions.check(
		_shown_parts(avatar) == OutfitDefs.parts_of(OutfitDefs.PEASANT),
		"archer then mage strips every ranger part and shows the peasant ones, got [%s]"
		% ", ".join(_shown_parts(avatar)),
	)
	_assertions.check(
		avatar.worn_outfit() == OutfitDefs.PEASANT, "and reports the peasant outfit"
	)

	avatar.apply_class("archer")
	_assertions.check(
		_shown_parts(avatar) == OutfitDefs.parts_of(OutfitDefs.RANGER),
		"mage then archer strips every peasant part and shows the ranger ones, got [%s]"
		% ", ".join(_shown_parts(avatar)),
	)
	_assertions.check(
		_body_scale(avatar) == Vector3(OutfitDefs.DRESSED_GIRTH, 1.0, OutfitDefs.DRESSED_GIRTH),
		"crossing between two outfits leaves the girth dressed, got %s" % _body_scale(avatar),
	)

	avatar.queue_free()


func _test_an_unknown_class_returns_the_avatar_to_bare() -> void:
	for class_id: String in ["", "no_such_class"]:
		var avatar := _spawn(5)
		avatar.apply_class("miner")
		avatar.apply_class(class_id)

		_assertions.check(
			avatar.worn_outfit() == "",
			'apply_class("%s") reports no outfit, got "%s"' % [class_id, avatar.worn_outfit()],
		)
		_assertions.check(
			_shown_parts(avatar).is_empty(),
			'apply_class("%s") hides every part, got [%s] shown'
			% [class_id, ", ".join(_shown_parts(avatar))],
		)
		_assertions.check(
			_body_scale(avatar) == Vector3.ONE,
			'apply_class("%s") widens the body back to girth 1.0, got %s'
			% [class_id, _body_scale(avatar)],
		)
		var stale := 0
		for mesh in _meshes(_part(avatar, CLOTH_PART)):
			for surface in mesh.mesh.get_surface_count():
				if mesh.get_surface_override_material(surface) != null:
					stale += 1
		_assertions.check(
			stale == 0,
			'apply_class("%s") clears the tint override rather than leaving a duplicate, %d left'
			% [class_id, stale],
		)

		avatar.queue_free()


func _test_worn_parts_deform_with_the_base_rig() -> void:
	var avatar := _spawn(6)
	var skeleton := avatar.get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
	_assertions.check(skeleton != null, "the base body still carries the shared rig")

	var checked := 0
	for class_id: String in ["archer", "mage"]:
		avatar.apply_class(class_id)
		for part_name: String in _shown_parts(avatar):
			for mesh in _meshes(_part(avatar, part_name)):
				checked += 1
				_assertions.check(
					mesh.skin != null,
					"%s/%s keeps its skin, so it bends with the bones instead of riding a transform"
					% [part_name, mesh.name],
				)
				_assertions.check(
					mesh.get_node_or_null(mesh.skeleton) == skeleton,
					"%s/%s is driven by the base body's own Skeleton3D, not its own idle copy"
					% [part_name, mesh.name],
				)
	_assertions.check(
		checked > 0, "the worn outfits contribute skinned meshes to check (%d)" % checked
	)

	avatar.queue_free()


func _test_the_tint_lands_on_cloth_and_spares_bare_skin() -> void:
	var avatar := _spawn(7)
	avatar.apply_class("mage")
	var tint := OutfitDefs.tint_for("mage")

	var cloth_surfaces := 0
	for mesh in _meshes(_part(avatar, CLOTH_PART)):
		for surface in mesh.mesh.get_surface_count():
			var source := mesh.mesh.surface_get_material(surface)
			if source == null or not source.resource_name.begins_with(CLOTH_MATERIAL):
				continue
			cloth_surfaces += 1
			var override := mesh.get_surface_override_material(surface) as BaseMaterial3D
			_assertions.check(
				override != null, "%s surface %d carries a tinted override" % [CLOTH_PART, surface]
			)
			if override == null:
				continue
			_assertions.check(
				override.albedo_color.is_equal_approx(tint),
				"%s wears the mage tint %s as albedo_color, got %s"
				% [CLOTH_PART, tint, override.albedo_color],
			)
			_assertions.check(
				not is_same(override, source),
				"the tint is a duplicate, so the vendor's shared %s material is left alone"
				% CLOTH_MATERIAL,
			)
			_assertions.check(
				override.albedo_texture != null,
				"the tinted material keeps its albedo texture, so the fabric detail survives",
			)
	_assertions.check(cloth_surfaces > 0, "%s has cloth surfaces to tint" % CLOTH_PART)

	var skin_surfaces := 0
	for mesh in _meshes(_part(avatar, SKIN_PART)):
		for surface in mesh.mesh.get_surface_count():
			var source := mesh.mesh.surface_get_material(surface)
			if source == null or not source.resource_name.begins_with(SKIN_MATERIAL):
				continue
			skin_surfaces += 1
			_assertions.check(
				mesh.get_surface_override_material(surface) == null,
				"the %s surface of %s is left untinted, so the bare hands stay skin-coloured"
				% [SKIN_MATERIAL, SKIN_PART],
			)
	_assertions.check(
		skin_surfaces > 0, "%s carries a %s surface to spare" % [SKIN_PART, SKIN_MATERIAL]
	)

	avatar.queue_free()


func _test_one_class_shares_one_tinted_material() -> void:
	var first := _spawn(8)
	var second := _spawn(9)
	first.apply_class("miner")
	second.apply_class("miner")

	var first_material := _cloth_override(first)
	var second_material := _cloth_override(second)
	_assertions.check(
		first_material != null and second_material != null,
		"both miners carry a tinted cloth material",
	)
	_assertions.check(
		is_same(first_material, second_material),
		"two miners share one tinted material rather than duplicating it per avatar",
	)

	first.queue_free()
	second.queue_free()


func _test_two_avatars_of_different_classes_do_not_share_state() -> void:
	var miner := _spawn(10)
	var archer := _spawn(11)
	miner.apply_class("miner")
	archer.apply_class("archer")

	_assertions.check(
		miner.worn_outfit() == OutfitDefs.PEASANT and archer.worn_outfit() == OutfitDefs.RANGER,
		"dressing one avatar does not redress the other",
	)
	_assertions.check(
		_shown_parts(miner) == OutfitDefs.parts_of(OutfitDefs.PEASANT),
		"the miner keeps only peasant parts, got [%s]" % ", ".join(_shown_parts(miner)),
	)
	_assertions.check(
		_shown_parts(archer) == OutfitDefs.parts_of(OutfitDefs.RANGER),
		"the archer keeps only ranger parts, got [%s]" % ", ".join(_shown_parts(archer)),
	)

	archer.apply_class("")
	_assertions.check(
		_shown_parts(miner) == OutfitDefs.parts_of(OutfitDefs.PEASANT)
		and _body_scale(miner) == Vector3(OutfitDefs.DRESSED_GIRTH, 1.0, OutfitDefs.DRESSED_GIRTH),
		"undressing the archer leaves the miner dressed",
	)
	_assertions.check(
		_cloth_override(miner) != null,
		"and leaves the miner's tint on, so the shared material cache is not cleared for everyone",
	)

	miner.queue_free()
	archer.queue_free()


func _test_a_class_frame_dresses_the_local_avatar() -> void:
	var root := MainScene.instantiate() as Node3D
	root.name = "OutfitClient"
	_world.add_child(root)
	var session := root.get_node("Session") as SessionScript
	var net := root.get_node("Session/Net") as NetClientScript
	await get_tree().process_frame
	await get_tree().process_frame

	net.ingest_text_frame(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100}]}}'
	)
	await get_tree().process_frame
	var local := session.avatar_for(1) as PlayerAvatar
	_assertions.check(local != null, "the session hands back the local avatar after welcome")
	if local == null:
		root.queue_free()
		return
	_assertions.check(
		local.worn_outfit() == "", "welcome leaves the local avatar bare"
	)

	net.ingest_text_frame('{"class":{"player":1,"class":"archer"}}')
	await get_tree().process_frame
	_assertions.check(
		local.worn_outfit() == OutfitDefs.RANGER,
		'an archer class frame dresses the local avatar with no reconnect, got "%s"'
		% local.worn_outfit(),
	)
	_assertions.check(
		_shown_parts(local) == OutfitDefs.parts_of(OutfitDefs.RANGER),
		"and shows exactly the ranger parts, got [%s]" % ", ".join(_shown_parts(local)),
	)

	net.ingest_text_frame('{"class":{"player":1,"class":""}}')
	await get_tree().process_frame
	_assertions.check(
		local.worn_outfit() == "",
		'an empty class frame undresses the local avatar, got "%s"' % local.worn_outfit(),
	)
	_assertions.check(
		_shown_parts(local).is_empty() and _body_scale(local) == Vector3.ONE,
		"and returns it to the bare girth, got [%s] shown at %s"
		% [", ".join(_shown_parts(local)), _body_scale(local)],
	)

	root.queue_free()


func _spawn(id: int) -> PlayerAvatar:
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	avatar.configure(id, TICK_MS)
	_avatars.add_child(avatar)
	return avatar


func _part(avatar: PlayerAvatar, part_name: String) -> Node3D:
	return avatar.get_node_or_null(NodePath("Outfit/%s" % part_name)) as Node3D


func _parts(avatar: PlayerAvatar) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for part_name: String in OutfitDefs.part_names():
		var part := _part(avatar, part_name)
		if part != null:
			found.append(part)
	return found


func _shown_parts(avatar: PlayerAvatar) -> PackedStringArray:
	var shown := PackedStringArray()
	for part_name: String in OutfitDefs.part_names():
		var part := _part(avatar, part_name)
		if part != null and part.visible:
			shown.append(part_name)
	return shown


func _body_scale(avatar: PlayerAvatar) -> Vector3:
	var body := avatar.get_node_or_null("Body") as Node3D
	return Vector3.ZERO if body == null else body.scale


func _cloth_override(avatar: PlayerAvatar) -> Material:
	for mesh in _meshes(_part(avatar, CLOTH_PART)):
		for surface in mesh.mesh.get_surface_count():
			var source := mesh.mesh.surface_get_material(surface)
			if source == null or not source.resource_name.begins_with(CLOTH_MATERIAL):
				continue
			return mesh.get_surface_override_material(surface)
	return null


static func _meshes(root: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if root == null:
		return found
	var mesh := root as MeshInstance3D
	if mesh != null and mesh.mesh != null:
		found.append(mesh)
	for child in root.get_children():
		found.append_array(_meshes(child))
	return found
