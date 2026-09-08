extends SceneTree


const SOURCE := "res://assets/quaternius/animations/UAL2_Standard.glb"
const OUTPUT := "res://assets/quaternius/animations/locomotion_library.tres"
const CLIPS: PackedStringArray = ["Idle_FoldArms", "Walk_Carry"]
const WALK_CLIP := "Walk_Carry"
const STANCE_FOOT := "ball_l"
const STANCE_LIFT := 0.02
const SAMPLES := 200


func _initialize() -> void:
	var scene: Node = (load(SOURCE) as PackedScene).instantiate()
	var player := scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var skeleton := scene.find_child("Skeleton3D", true, false) as Skeleton3D
	var library := AnimationLibrary.new()
	for clip in CLIPS:
		if not player.has_animation(clip):
			push_error("%s has no clip %s; it has %s" % [SOURCE, clip, player.get_animation_list()])
			quit(1)
			return
		library.add_animation(clip, player.get_animation(clip).duplicate(true))
	var error := ResourceSaver.save(library, OUTPUT)
	if error != OK:
		push_error("saving %s failed: %s" % [OUTPUT, error_string(error)])
		quit(1)
		return

	var saved := ResourceLoader.load(OUTPUT, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE) as AnimationLibrary
	for clip in saved.get_animation_list():
		var animation := saved.get_animation(clip)
		print(
			"BAKED %s length %.3f loop %d tracks %d first %s"
			% [clip, animation.length, animation.loop_mode, animation.get_track_count(), animation.track_get_path(0)]
		)
	print(
		"WALK %s ground speed %.4f u/s, measured on %s while planted"
		% [WALK_CLIP, _ground_speed(skeleton, saved.get_animation(WALK_CLIP)), STANCE_FOOT]
	)
	scene.free()
	quit()


static func _ground_speed(skeleton: Skeleton3D, walk: Animation) -> float:
	var foot := skeleton.find_bone(STANCE_FOOT)
	var heights := PackedFloat32Array()
	var depths := PackedFloat32Array()
	for k in SAMPLES + 1:
		_pose(skeleton, walk, walk.length * k / SAMPLES)
		var origin := _global_pose(skeleton, foot).origin
		heights.append(origin.y)
		depths.append(origin.z)
	var floor_y := heights[0]
	for y in heights:
		floor_y = minf(floor_y, y)
	var speeds := PackedFloat32Array()
	var dt := walk.length / SAMPLES
	for k in SAMPLES:
		if heights[k] < floor_y + STANCE_LIFT and heights[k + 1] < floor_y + STANCE_LIFT:
			speeds.append(absf(depths[k + 1] - depths[k]) / dt)
	if speeds.is_empty():
		push_error("%s never plants %s within %.3f u of its lowest point" % [walk.resource_name, STANCE_FOOT, STANCE_LIFT])
		return 0.0
	speeds.sort()
	return speeds[speeds.size() / 2]


static func _pose(skeleton: Skeleton3D, animation: Animation, time: float) -> void:
	for track in animation.get_track_count():
		var path := String(animation.track_get_path(track))
		var bone := skeleton.find_bone(path.get_slice(":", 1))
		if bone < 0:
			continue
		match animation.track_get_type(track):
			Animation.TYPE_POSITION_3D:
				skeleton.set_bone_pose_position(bone, animation.position_track_interpolate(track, time))
			Animation.TYPE_ROTATION_3D:
				skeleton.set_bone_pose_rotation(bone, animation.rotation_track_interpolate(track, time))
			Animation.TYPE_SCALE_3D:
				skeleton.set_bone_pose_scale(bone, animation.scale_track_interpolate(track, time))


static func _global_pose(skeleton: Skeleton3D, bone: int) -> Transform3D:
	var pose := skeleton.get_bone_pose(bone)
	var parent := skeleton.get_bone_parent(bone)
	while parent >= 0:
		pose = skeleton.get_bone_pose(parent) * pose
		parent = skeleton.get_bone_parent(parent)
	return pose
