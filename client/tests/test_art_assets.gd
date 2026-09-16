extends Node3D


const ArtContract := preload("res://scripts/art_contract.gd")
const Assertions := preload("res://tests/assertions.gd")

const SKELETON_PATH := "Skeleton3D"
const REGION_PREFIX := "region_"
const LIBRARY := "proto"
const VARIANT_PARITY_DEGREES := 0.1
const REST_SOURCE_PARITY_DEGREES := 0.5
const PELVIS_EPSILON := 0.02
const PELVIS_SAMPLES := 6
const SWING_CONTACT_FRAME := 7
const SWING_HAND_TRAVEL := 0.3
const BODY_TRIANGLES_MIN := 4000
const BODY_TRIANGLES_MAX := 8000
const PIECE_TRIANGLES_MIN := 300
const PIECE_TRIANGLES_MAX := 2000
const ITEM_TRIANGLES_MIN := 200
const ITEM_TRIANGLES_MAX := 2000
const PROP_TRIANGLES_MIN := 300
const PROP_TRIANGLES_MAX := 3000
const GROUND_EPSILON := 0.02
const WEIGHT_SUM_TOLERANCE := 0.002

var _assertions: Assertions = null
var _finished := false
var _contract: ArtContract = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures if _assertions != null else PackedStringArray()


func get_assertion_count() -> int:
	return _assertions.assertion_count if _assertions != null else 0


func _ready() -> void:
	_assertions = Assertions.new()
	_contract = ArtContract.new(ArtContract.read_text(ArtContract.PATH))
	_assertions.check(_contract.is_valid(), "the contract parses clean, got %s" % [_contract.errors])
	if _contract.is_valid():
		var rigs := {}
		for name in _contract.variants:
			rigs[name] = _spawn(_contract.variants[name].glb)
		_test_each_rig_carries_exactly_the_contract_bones(rigs)
		_test_every_variant_shares_the_clip_rig_rest_orientations(rigs)
		_test_the_clip_rig_rests_like_the_rest_source(rigs)
		_test_each_region_is_a_skinned_mesh_weighted_to_its_own_bones(rigs)
		_test_each_body_stays_within_the_triangle_budget(rigs)
		_test_each_piece_is_a_skinned_mesh_weighted_to_its_slot_bones(rigs[_contract.clip_rig])
		_test_each_hand_item_is_a_static_mesh_gripped_at_the_origin()
		_test_each_prop_is_a_static_mesh_standing_on_its_origin()
		_test_the_clip_library_matches_the_contract()
		await _test_the_imp_plays_idle_at_its_own_pelvis_height()
		await _test_swing_moves_the_grip_hand()
	_finished = true


func _test_each_body_stays_within_the_triangle_budget(rigs: Dictionary) -> void:
	for name in rigs:
		var skeleton := _skeleton(rigs[name])
		var triangles := 0
		for region in _contract.regions:
			var mesh := skeleton.get_node_or_null(REGION_PREFIX + region) as MeshInstance3D
			if mesh == null:
				continue
			for surface in mesh.mesh.get_surface_count():
				triangles += mesh.mesh.surface_get_array_index_len(surface) / 3
		_assertions.check(
			triangles >= BODY_TRIANGLES_MIN and triangles <= BODY_TRIANGLES_MAX,
			"%s body has %d triangles, within %d to %d" % [name, triangles, BODY_TRIANGLES_MIN, BODY_TRIANGLES_MAX],
		)


func _test_each_piece_is_a_skinned_mesh_weighted_to_its_slot_bones(rig: Node3D) -> void:
	var skeleton := _skeleton(rig)
	var found := PackedStringArray()
	for child in skeleton.get_children():
		if child is MeshInstance3D and not String(child.name).begins_with(REGION_PREFIX):
			found.append(child.name)
	found.sort()
	var expected := PackedStringArray(_contract.pieces.keys())
	expected.sort()
	_assertions.check(found == expected, "%s carries one mesh per contract piece, got %s" % [_contract.clip_rig, found])
	for item in _contract.pieces:
		var mesh := skeleton.get_node_or_null(NodePath(item)) as MeshInstance3D
		if mesh == null:
			continue
		var bones := PackedStringArray()
		for region in _contract.slot_regions[_contract.pieces[item].slot]:
			bones.append_array(_contract.regions[region])
		_assertions.check(
			mesh.skin != null and mesh.get_node(mesh.skeleton) == skeleton,
			"piece %s is skinned to the rig skeleton" % item,
		)
		var strays := _vertices_off_region(mesh, skeleton, bones)
		_assertions.check(
			strays.is_empty(),
			"piece %s weights every vertex only to bones of slot %s, summing to 1, strays %s"
			% [item, _contract.pieces[item].slot, strays],
		)
		var triangles := _triangles(mesh.mesh)
		_assertions.check(
			triangles >= PIECE_TRIANGLES_MIN and triangles <= PIECE_TRIANGLES_MAX,
			"piece %s has %d triangles, within %d to %d" % [item, triangles, PIECE_TRIANGLES_MIN, PIECE_TRIANGLES_MAX],
		)


func _test_each_hand_item_is_a_static_mesh_gripped_at_the_origin() -> void:
	for item in _contract.hand_items:
		var scene := load(_contract.hand_items[item]) as PackedScene
		_assertions.check(scene != null, "%s loads as a scene" % _contract.hand_items[item])
		if scene == null:
			continue
		var instance := scene.instantiate() as Node3D
		add_child(instance)
		var meshes := instance.find_children("*", "MeshInstance3D", true, false)
		_assertions.check(
			meshes.size() == 1 and instance.find_children("*", "Skeleton3D", true, false).is_empty(),
			"%s holds one static mesh and no skeleton, got %d meshes" % [item, meshes.size()],
		)
		if meshes.size() == 1:
			var mesh := meshes[0] as MeshInstance3D
			var bounds := mesh.global_transform * mesh.get_aabb()
			_assertions.check(bounds.grow(0.001).has_point(Vector3.ZERO), "%s bounds contain its grip origin" % item)
			_assertions.check(
				bounds.size.y >= bounds.size.x and bounds.size.y >= bounds.size.z or item == "shield",
				"%s runs its long axis along +Y, size %s" % [item, bounds.size],
			)
			var triangles := _triangles(mesh.mesh)
			_assertions.check(
				triangles >= ITEM_TRIANGLES_MIN and triangles <= ITEM_TRIANGLES_MAX,
				"%s has %d triangles, within %d to %d" % [item, triangles, ITEM_TRIANGLES_MIN, ITEM_TRIANGLES_MAX],
			)
		instance.queue_free()


func _test_each_prop_is_a_static_mesh_standing_on_its_origin() -> void:
	for kind in _contract.props:
		for state in _contract.props[kind]:
			var path: String = _contract.props[kind][state]
			var scene := load(path) as PackedScene
			_assertions.check(scene != null, "%s loads as a scene" % path)
			if scene == null:
				continue
			var instance := scene.instantiate() as Node3D
			add_child(instance)
			var meshes := instance.find_children("*", "MeshInstance3D", true, false)
			_assertions.check(
				meshes.size() == 1 and instance.find_children("*", "Skeleton3D", true, false).is_empty(),
				"%s holds one static mesh and no skeleton, got %d meshes" % [path.get_file(), meshes.size()],
			)
			if meshes.size() == 1:
				var mesh := meshes[0] as MeshInstance3D
				var triangles := _triangles(mesh.mesh)
				_assertions.check(
					triangles >= PROP_TRIANGLES_MIN and triangles <= PROP_TRIANGLES_MAX,
					"%s has %d triangles, within %d to %d"
					% [path.get_file(), triangles, PROP_TRIANGLES_MIN, PROP_TRIANGLES_MAX],
				)
				var lowest := INF
				for surface in mesh.mesh.get_surface_count():
					var vertices: PackedVector3Array = mesh.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
					for vertex in vertices:
						lowest = minf(lowest, (mesh.global_transform * vertex).y)
				_assertions.check(
					absf(lowest) <= GROUND_EPSILON,
					"%s stands on its origin, lowest vertex at y %.4f" % [path.get_file(), lowest],
				)
			instance.queue_free()


func _triangles(mesh: Mesh) -> int:
	var triangles := 0
	for surface in mesh.get_surface_count():
		triangles += mesh.surface_get_array_index_len(surface) / 3
	return triangles


func _test_each_rig_carries_exactly_the_contract_bones(rigs: Dictionary) -> void:
	var expected := _contract.bone_names()
	expected.sort()
	for name in rigs:
		var skeleton := _skeleton(rigs[name])
		var names := PackedStringArray()
		for index in skeleton.get_bone_count():
			names.append(skeleton.get_bone_name(index))
		names.sort()
		_assertions.check(names == expected, "%s bones equal the contract bones, got %s" % [name, names])


func _test_every_variant_shares_the_clip_rig_rest_orientations(rigs: Dictionary) -> void:
	var reference := _skeleton(rigs[_contract.clip_rig])
	for name in rigs:
		var skeleton := _skeleton(rigs[name])
		var worst := _worst_rest_angle(reference, skeleton)
		_assertions.check(
			worst[1] <= VARIANT_PARITY_DEGREES,
			"%s rest orientations match %s within %.2f deg, worst %s at %.4f deg"
			% [name, _contract.clip_rig, VARIANT_PARITY_DEGREES, worst[0], worst[1]],
		)


func _test_the_clip_rig_rests_like_the_rest_source(rigs: Dictionary) -> void:
	var source := _spawn(_contract.rest_source)
	var skeletons := source.find_children("*", "Skeleton3D", true, false)
	_assertions.check(
		skeletons.size() == 1,
		"%s holds exactly one Skeleton3D, got %d" % [_contract.rest_source.get_file(), skeletons.size()],
	)
	if skeletons.size() != 1:
		source.queue_free()
		return
	var worst := _worst_rest_angle(skeletons[0], _skeleton(rigs[_contract.clip_rig]))
	_assertions.check(
		worst[1] <= REST_SOURCE_PARITY_DEGREES,
		"%s rest orientations match %s within %.1f deg, worst %s at %.4f deg"
		% [_contract.clip_rig, _contract.rest_source.get_file(), REST_SOURCE_PARITY_DEGREES, worst[0], worst[1]],
	)
	source.queue_free()


func _test_each_region_is_a_skinned_mesh_weighted_to_its_own_bones(rigs: Dictionary) -> void:
	var expected := PackedStringArray()
	for region in _contract.regions:
		expected.append(REGION_PREFIX + region)
	expected.sort()
	for name in rigs:
		var skeleton := _skeleton(rigs[name])
		var found := PackedStringArray()
		for child in skeleton.get_children():
			if child is MeshInstance3D and String(child.name).begins_with(REGION_PREFIX):
				found.append(child.name)
		found.sort()
		_assertions.check(
			found == expected,
			"%s has one mesh per region under Skeleton3D, got %s" % [name, found],
		)
		for region in _contract.regions:
			var mesh := skeleton.get_node_or_null(REGION_PREFIX + region) as MeshInstance3D
			if mesh == null:
				continue
			_assertions.check(
				mesh.skin != null and mesh.get_node(mesh.skeleton) == skeleton,
				"%s %s is skinned to the rig skeleton" % [name, mesh.name],
			)
			var strays := _vertices_off_region(mesh, skeleton, _contract.regions[region])
			_assertions.check(
				strays.is_empty(),
				"%s %s weights every vertex only to %s, summing to 1, strays %s"
				% [name, mesh.name, _contract.regions[region], strays],
			)


func _test_the_clip_library_matches_the_contract() -> void:
	var library := load(_contract.clips_glb) as AnimationLibrary
	_assertions.check(library != null, "%s imports as an AnimationLibrary" % _contract.clips_glb)
	if library == null:
		return
	var names := PackedStringArray()
	for clip in library.get_animation_list():
		names.append(clip)
	names.sort()
	var expected := PackedStringArray(_contract.clips.keys())
	expected.sort()
	_assertions.check(names == expected, "the library clips equal the contract clips, got %s" % [names])
	var track_prefix := "%s/%s:" % [_contract.armature, SKELETON_PATH]
	for clip in _contract.clips:
		if not library.has_animation(clip):
			continue
		var animation := library.get_animation(clip)
		var loop_mode := Animation.LOOP_LINEAR if _contract.clips[clip].loop else Animation.LOOP_NONE
		_assertions.check(
			animation.loop_mode == loop_mode,
			"%s loop mode is %d from the import settings, got %d" % [clip, loop_mode, animation.loop_mode],
		)
		_assertions.check_near(
			animation.length, _contract.clip_length(clip), 1.0e-4, "%s lasts its contract frames" % clip
		)
		var positions := PackedStringArray()
		var others := PackedStringArray()
		var rotations := 0
		for track in animation.get_track_count():
			var path := String(animation.track_get_path(track))
			var type := animation.track_get_type(track)
			if not path.begins_with(track_prefix) or path.ends_with(":root"):
				others.append(path)
			elif type == Animation.TYPE_ROTATION_3D:
				rotations += 1
			elif type == Animation.TYPE_POSITION_3D:
				positions.append(path.get_slice(":", 1))
			else:
				others.append("%s type %d" % [path, type])
		_assertions.check(
			others.is_empty() and rotations > 0 and positions == PackedStringArray(["pelvis"]),
			"%s keys %d bone rotations plus one pelvis position, got positions %s and others %s"
			% [clip, rotations, positions, others],
		)


func _test_the_imp_plays_idle_at_its_own_pelvis_height() -> void:
	var imp := _spawn(_contract.variants["imp"].glb)
	var skeleton := _skeleton(imp)
	var human := _skeleton(_spawn(_contract.variants[_contract.clip_rig].glb))
	var pelvis := skeleton.find_bone("pelvis")
	var rest_height := skeleton.get_bone_global_rest(pelvis).origin.y
	_assertions.check_near(
		_contract.motion_scale("imp"),
		rest_height / human.get_bone_global_rest(human.find_bone("pelvis")).origin.y,
		0.002,
		"the contract imp motion scale equals the imported pelvis height ratio",
	)
	var player := _player_on(imp)
	var clip := _contract.clip_for("idle", "")
	var unscaled := await _pelvis_height(player, skeleton, clip, 0.0)
	_assertions.check(
		absf(unscaled - rest_height) > 0.2,
		"without motion_scale the human pelvis track lifts the imp pelvis to %.3f" % unscaled,
	)
	skeleton.motion_scale = _contract.motion_scale("imp")
	var worst := 0.0
	for sample in PELVIS_SAMPLES:
		var time := _contract.clip_length(clip) * sample / PELVIS_SAMPLES
		worst = maxf(worst, absf(await _pelvis_height(player, skeleton, clip, time) - rest_height))
	_assertions.check(
		worst <= PELVIS_EPSILON,
		"with motion_scale %.3f the imp pelvis stays within %.2f m of its rest %.3f while idling, worst %.4f"
		% [skeleton.motion_scale, PELVIS_EPSILON, rest_height, worst],
	)


func _test_swing_moves_the_grip_hand() -> void:
	var human := _spawn(_contract.variants[_contract.clip_rig].glb)
	var skeleton := _skeleton(human)
	var player := _player_on(human)
	var hand := skeleton.find_bone("hand_r")
	await _seek(player, _contract.clip_for("idle", ""), 0.0)
	var idle := skeleton.get_bone_global_pose(hand).origin
	await _seek(player, _contract.clip_for("swing", ""), float(SWING_CONTACT_FRAME) / _contract.fps)
	var contact := skeleton.get_bone_global_pose(hand).origin
	_assertions.check(
		idle.distance_to(contact) >= SWING_HAND_TRAVEL,
		"the swing contact frame carries hand_r %.3f m from idle" % idle.distance_to(contact),
	)
	_assertions.check(
		(contact - idle).dot(Vector3.MODEL_FRONT) > 0.0,
		"and in front of the idle hand along the model front, idle %s contact %s" % [idle, contact],
	)


func _spawn(path: String) -> Node3D:
	var instance: Node3D = (load(path) as PackedScene).instantiate()
	add_child(instance)
	return instance


func _skeleton(rig: Node3D) -> Skeleton3D:
	return rig.get_node("%s/%s" % [_contract.armature, SKELETON_PATH]) as Skeleton3D


func _player_on(rig: Node3D) -> AnimationPlayer:
	var player := AnimationPlayer.new()
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	rig.add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library(LIBRARY, load(_contract.clips_glb))
	return player


func _seek(player: AnimationPlayer, clip: String, time: float) -> void:
	player.play("%s/%s" % [LIBRARY, clip])
	for pass_index in 2:
		player.seek(time, true)
		await get_tree().process_frame


func _pelvis_height(player: AnimationPlayer, skeleton: Skeleton3D, clip: String, time: float) -> float:
	await _seek(player, clip, time)
	return skeleton.get_bone_global_pose(skeleton.find_bone("pelvis")).origin.y


func _worst_rest_angle(reference: Skeleton3D, skeleton: Skeleton3D) -> Array:
	var worst := ["", 0.0]
	for name in _contract.bone_names():
		var expected := _rest_rotation(reference, name)
		var actual := _rest_rotation(skeleton, name)
		var degrees := rad_to_deg(expected.angle_to(actual))
		if degrees > worst[1]:
			worst = [name, degrees]
	return worst


func _rest_rotation(skeleton: Skeleton3D, bone: String) -> Quaternion:
	var rest := skeleton.get_bone_global_rest(skeleton.find_bone(bone))
	return (skeleton.global_basis * rest.basis).get_rotation_quaternion()


func _vertices_off_region(mesh: MeshInstance3D, skeleton: Skeleton3D, bones: PackedStringArray) -> PackedStringArray:
	var strays := PackedStringArray()
	for surface in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var influences := joints.size() / vertex_count
		for vertex in vertex_count:
			var base := vertex * influences
			var total := 0.0
			var off := PackedStringArray()
			for slot in influences:
				if is_zero_approx(weights[base + slot]):
					continue
				total += weights[base + slot]
				var bone := _bind_bone_name(mesh.skin, skeleton, joints[base + slot])
				if not bones.has(bone):
					off.append(bone)
			if not off.is_empty() or absf(total - 1.0) > WEIGHT_SUM_TOLERANCE:
				strays.append("surface %d vertex %d -> %s total %.3f" % [surface, vertex, off, total])
				if strays.size() >= 3:
					return strays
	return strays


func _bind_bone_name(skin: Skin, skeleton: Skeleton3D, bind: int) -> String:
	var name := skin.get_bind_name(bind)
	if name.is_empty():
		name = skeleton.get_bone_name(skin.get_bind_bone(bind))
	return name
