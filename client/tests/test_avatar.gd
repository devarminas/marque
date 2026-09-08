extends Node3D


const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")
const TickClock := preload("res://scripts/tick_clock.gd")
const Assertions := preload("res://tests/assertions.gd")

const TICK_MS := 100
const POSITION_EPSILON := 1.0e-5
const YAW_EPSILON := 0.0175
const TURN_FRAMES := 40
const BODY_SCENE_PATH := "res://assets/quaternius/base_characters/Superhero_Male_FullBody.gltf"
const BODY_SKIN := "SuperHero_Male"
const BASE_RIG_BONES := 65
const BIND_HEIGHT := 1.8196
const BIND_HEIGHT_EPSILON := 0.02
const SERVER_WALK_SPEED := 3.0

@onready var _remote_players: Node3D = $RemotePlayers

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

	_test_scene_instantiates_and_configures()
	_test_a_vanished_body_draws_magenta()
	_test_position_tracks_the_walker_over_simulated_time()
	_test_two_avatars_do_not_share_state()
	_test_a_pathless_avatar_idles()
	await _test_walk_animation_follows_the_walker()
	await _test_a_clock_drives_the_avatar_without_being_told_each_tick()
	await _test_the_body_turns_to_face_its_direction_of_travel()
	await _test_facing_can_be_turned_off_without_moving_the_body()

	_finished = true


func _spawn(id: int) -> PlayerAvatar:
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	avatar.configure(id, TICK_MS)
	_remote_players.add_child(avatar)
	return avatar


func _test_scene_instantiates_and_configures() -> void:
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	_assertions.check(avatar != null, "player_avatar.tscn instantiates")
	_assertions.check(avatar is Node3D, "its root is a Node3D that carries a world transform")
	_assertions.check(
		avatar.get_script() != null, "its root script compiled and is attached"
	)
	_assertions.check(avatar.player_id == 0, "an unconfigured avatar has no player id")

	avatar.configure(7, TICK_MS)
	_assertions.check(avatar.player_id == 7, "configure() records the player id")

	_remote_players.add_child(avatar)
	_assertions.check(
		avatar.get_parent() == _remote_players, "it parents under the RemotePlayers container"
	)

	avatar.teleport_to(3.0, -4.0)
	_assertions.check_position_near(
		Vector2(avatar.position.x, avatar.position.z),
		Vector2(3.0, -4.0),
		POSITION_EPSILON,
		"teleport_to() places it on the ground plane",
	)
	_assertions.check_near(
		avatar.position.y, avatar.ground_y, POSITION_EPSILON, "its feet sit at ground_y"
	)

	var skeleton := avatar.get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
	_assertions.check(skeleton != null, "the rig's Skeleton3D exists under Body/Armature")
	_assertions.check(
		skeleton != null and skeleton.get_bone_count() == BASE_RIG_BONES,
		"the Universal Base rig has the %d bones every Quaternius part shares, got %d"
		% [BASE_RIG_BONES, 0 if skeleton == null else skeleton.get_bone_count()],
	)
	var skinned := 0
	var skin_names := PackedStringArray()
	var body_height := 0.0
	if skeleton != null:
		for node in skeleton.get_children():
			var mesh := node as MeshInstance3D
			if mesh == null:
				continue
			skinned += 1
			skin_names.append(String(mesh.name))
			if mesh.name == BODY_SKIN and mesh.mesh != null:
				body_height = mesh.mesh.get_aabb().size.y
			_assertions.check(
				mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
				"%s casts a shadow" % mesh.name,
			)
			_assertions.check(
				mesh.skin != null and mesh.get_node_or_null(mesh.skeleton) == skeleton,
				"%s is skinned to the shared rig, not merely parented under it" % mesh.name,
			)
			var surface_material := mesh.get_active_material(0) if mesh.mesh != null and mesh.mesh.get_surface_count() > 0 else null
			_assertions.check(
				surface_material != null, "%s has a material" % mesh.name
			)
			if surface_material != null and "shading_mode" in surface_material:
				_assertions.check(
					surface_material.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED,
					"%s is lit, not unlit" % mesh.name,
				)
	_assertions.check(skinned > 0, "the skeleton carries skinned meshes (%d)" % skinned)
	_assertions.check(
		skin_names.has(BODY_SKIN),
		"the %s skin is among the skinned meshes, got [%s]" % [BODY_SKIN, ", ".join(skin_names)],
	)
	_assertions.check(
		absf(body_height - BIND_HEIGHT) <= BIND_HEIGHT_EPSILON,
		"the body keeps its authored %.3f u bind height, so the import root_scale is 1.0, got %f"
		% [BIND_HEIGHT, body_height],
	)

	var body := avatar.get_node_or_null("Body") as Node3D
	_assertions.check(
		body != null and body.scene_file_path == BODY_SCENE_PATH,
		"Body is the Universal Base glTF instance, got \"%s\""
		% ("" if body == null else body.scene_file_path),
	)
	_assertions.check(
		body != null and body.transform.basis.z.z < 0.0,
		"the +Z-authored body is turned to face the avatar's -Z forward",
	)

	var animation := avatar.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_assertions.check(animation != null, "an AnimationPlayer is authored on the avatar")
	_assertions.check(
		animation != null and animation.has_animation(PlayerAvatar.WALK_ANIM),
		"the walk animation %s is in the library" % PlayerAvatar.WALK_ANIM,
	)
	_assertions.check(
		animation != null and animation.has_animation(PlayerAvatar.IDLE_ANIM),
		"the idle animation %s is in the library" % PlayerAvatar.IDLE_ANIM,
	)
	_assertions.check(
		PlayerAvatar.IDLE_ANIM == "ual2/Idle_FoldArms",
		"idle is UAL2 Idle_FoldArms_Loop; Godot strips the _Loop suffix on import, got \"%s\""
		% PlayerAvatar.IDLE_ANIM,
	)
	_assertions.check(
		PlayerAvatar.WALK_ANIM == "ual2/Walk_Carry",
		"walk is UAL2 Walk_Carry_Loop; Godot strips the _Loop suffix on import, got \"%s\""
		% PlayerAvatar.WALK_ANIM,
	)

	var clip_lengths := {PlayerAvatar.IDLE_ANIM: 2.5, PlayerAvatar.WALK_ANIM: 2.0}
	for clip_name in clip_lengths:
		var clip: Animation = animation.get_animation(clip_name) if animation != null else null
		_assertions.check(clip != null, "%s resolves to an Animation" % clip_name)
		if clip == null:
			continue
		_assertions.check(
			clip.loop_mode == Animation.LOOP_LINEAR,
			"the %s clip loops linearly, so a held walk never plays once and freezes" % clip_name,
		)
		_assertions.check(
			is_equal_approx(clip.length, clip_lengths[clip_name]),
			"the %s clip is %.1f s of the vendor's motion, got %f"
			% [clip_name, clip_lengths[clip_name], clip.length],
		)
		_assertions.check(
			body != null
			and clip.get_track_count() > 0
			and body.has_node(NodePath(String(clip.track_get_path(0)).get_slice(":", 0))),
			"the %s clip's tracks resolve on the Body skeleton" % clip_name,
		)

	_assertions.check(
		animation != null and animation.root_node == NodePath("../Body"),
		"the AnimationPlayer drives the Body rig",
	)

	var hp_label := avatar.get_node_or_null("HpLabel") as Label3D
	_assertions.check(
		hp_label != null and is_equal_approx(hp_label.position.y, 2.0),
		"the HP label floats just above the 1.7 u head, got %f"
		% (0.0 if hp_label == null else hp_label.position.y),
	)

	var fallback := avatar.get_node_or_null("MissingBody") as MeshInstance3D
	_assertions.check(
		fallback != null and not fallback.visible,
		"a healthy body keeps the magenta fallback hidden",
	)

	avatar.queue_free()


func _test_a_vanished_body_draws_magenta() -> void:
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	var body := avatar.get_node("Body")
	avatar.remove_child(body)
	body.queue_free()
	avatar.configure(61, TICK_MS)
	_remote_players.add_child(avatar)

	var fallback := avatar.get_node_or_null("MissingBody") as MeshInstance3D
	_assertions.check(
		fallback != null and fallback.visible, "a vanished body shows the magenta fallback"
	)
	var material := fallback.get_active_material(0) if fallback != null else null
	var albedo := Color(0.0, 0.0, 0.0, 0.0)
	if material != null and "albedo_color" in material:
		albedo = material.albedo_color
	_assertions.check(
		is_equal_approx(albedo.r, 0.95)
		and is_equal_approx(albedo.g, 0.08)
		and is_equal_approx(albedo.b, 0.85)
		and is_equal_approx(albedo.a, 1.0),
		"the fallback is the palette's magenta, not a default white, got %s" % albedo,
	)

	avatar.queue_free()


func _test_position_tracks_the_walker_over_simulated_time() -> void:
	var avatar := _spawn(1)
	avatar.teleport_to(0.0, 0.0)
	avatar.follow_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0)]), 100, 2.0)

	avatar.update_to_tick(100)
	_assertions.check_position_near(
		_ground(avatar), Vector2(0.0, 0.0), POSITION_EPSILON, "at start_tick it is at points[0]"
	)

	avatar.update_to_tick(105)
	_assertions.check_position_near(
		_ground(avatar), Vector2(1.0, 0.0), POSITION_EPSILON, "5 ticks in it has walked 1.0 unit"
	)

	avatar.update_to_tick(125)
	_assertions.check_position_near(
		_ground(avatar), Vector2(5.0, 0.0), POSITION_EPSILON, "halfway through it is halfway along"
	)

	avatar.update_to_tick(105)
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(1.0, 0.0),
		POSITION_EPSILON,
		"replaying an earlier tick lands back where that tick was",
	)
	avatar.update_to_tick(90)
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(0.0, 0.0),
		POSITION_EPSILON,
		"a tick before start_tick clamps to points[0] rather than rewinding past it",
	)

	avatar.update_to_tick(1000)
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(10.0, 0.0),
		POSITION_EPSILON,
		"far past the end it holds at the final point",
	)
	_assertions.check(avatar.is_idle_at_tick(1000), "and reports itself idle")
	_assertions.check(not avatar.is_idle_at_tick(120), "but not while it is still walking")

	avatar.follow_path(PackedVector2Array([Vector2(10.0, 0.0), Vector2(10.0, 6.0)]), 200, 3.0)
	avatar.update_to_tick(210)
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(10.0, 3.0),
		POSITION_EPSILON,
		"it walks the replacement path, not the old one",
	)

	avatar.queue_free()


func _test_two_avatars_do_not_share_state() -> void:
	var first := _spawn(11)
	var second := _spawn(12)
	first.follow_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0)]), 0, 1.0)
	second.follow_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.0, -10.0)]), 0, 1.0)

	first.update_to_tick(20)
	second.update_to_tick(20)

	_assertions.check(first.player_id == 11 and second.player_id == 12, "ids stay distinct")
	_assertions.check_position_near(
		_ground(first), Vector2(2.0, 0.0), POSITION_EPSILON, "the first avatar walked east"
	)
	_assertions.check_position_near(
		_ground(second), Vector2(0.0, -2.0), POSITION_EPSILON, "the second walked north"
	)

	first.queue_free()
	second.queue_free()


func _test_a_pathless_avatar_idles() -> void:
	var avatar := _spawn(51)
	var animation := avatar.get_node_or_null("AnimationPlayer") as AnimationPlayer

	avatar.update_to_tick(0)
	_assertions.check(
		animation != null and animation.current_animation == PlayerAvatar.IDLE_ANIM,
		"a pathless avatar idles on %s, got \"%s\""
		% [PlayerAvatar.IDLE_ANIM, "" if animation == null else animation.current_animation],
	)

	avatar.queue_free()


func _test_walk_animation_follows_the_walker() -> void:
	var avatar := _spawn(2)
	var animation := avatar.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_assertions.check(
		animation != null and animation.current_animation.is_empty(),
		"an avatar with no path plays nothing",
	)

	avatar.follow_path(
		PackedVector2Array([Vector2(0.0, 0.0), Vector2(6.0, 0.0)]), 0, SERVER_WALK_SPEED
	)
	avatar.update_to_tick(5)
	_assertions.check(
		animation != null and animation.current_animation == PlayerAvatar.WALK_ANIM,
		"a mid-path tick runs %s, got \"%s\""
		% [PlayerAvatar.WALK_ANIM, "" if animation == null else animation.current_animation],
	)
	_assertions.check(
		is_equal_approx(PlayerAvatar.WALK_CLIP_SPEED, 0.65),
		"Walk_Carry covers 0.65 u/s, measured by bake_ual2_library.gd, so a 3.0 u/s path plays it"
		+ " at 4.62x, got %f" % PlayerAvatar.WALK_CLIP_SPEED,
	)
	_assertions.check(
		animation != null
		and is_equal_approx(
			animation.speed_scale, SERVER_WALK_SPEED / PlayerAvatar.WALK_CLIP_SPEED
		),
		"the walk is scaled to match the server's stride, got %f"
		% (0.0 if animation == null else animation.speed_scale),
	)

	avatar.update_to_tick(10_000)
	_assertions.check(
		animation != null and animation.current_animation == PlayerAvatar.IDLE_ANIM,
		"a far-future tick idles on %s, got \"%s\""
		% [PlayerAvatar.IDLE_ANIM, "" if animation == null else animation.current_animation],
	)

	avatar.update_to_tick(5)
	_assertions.check(
		animation != null and animation.current_animation == PlayerAvatar.WALK_ANIM,
		"a rewound tick re-derives the walk, got \"%s\""
		% ("" if animation == null else animation.current_animation),
	)

	avatar.queue_free()


func _test_a_clock_drives_the_avatar_without_being_told_each_tick() -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)
	clock.anchor(0, TICK_MS)

	var avatar := _spawn(21)
	avatar.clock = clock
	avatar.follow_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(8.0, 0.0)]), 0, 2.0)

	await get_tree().process_frame
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(0.0, 0.0),
		POSITION_EPSILON,
		"at the anchor tick the clock-driven avatar is at points[0]",
	)

	fake.advance_msec(15 * TICK_MS)
	await get_tree().process_frame
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(3.0, 0.0),
		POSITION_EPSILON,
		"15 ticks of clock time later it has walked 3.0 units on its own",
	)

	avatar.queue_free()


func _test_the_body_turns_to_face_its_direction_of_travel() -> void:
	var avatar := _spawn(31)
	_assertions.check(avatar.face_travel_direction, "facing is on by default")

	avatar.follow_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(20.0, 0.0)]), 0, 2.0)
	for _frame in TURN_FRAMES:
		avatar.update_to_tick(10)
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, -PI * 0.5)),
		0.0,
		YAW_EPSILON,
		"walking east settles the body at a yaw of -90 degrees (yaw %.4f rad)" % avatar.rotation.y,
	)

	avatar.follow_path(PackedVector2Array([Vector2(20.0, 0.0), Vector2(20.0, 20.0)]), 0, 2.0)
	for _frame in TURN_FRAMES:
		avatar.update_to_tick(10)
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, PI)),
		0.0,
		YAW_EPSILON,
		"walking toward +Z settles the body at a yaw of 180 degrees (yaw %.4f rad)" % avatar.rotation.y,
	)

	var arrived_yaw: float = avatar.rotation.y
	for _frame in TURN_FRAMES:
		avatar.update_to_tick(10_000)
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, arrived_yaw)),
		0.0,
		YAW_EPSILON,
		"on arrival it holds its heading rather than snapping to a default (yaw %.4f rad)" % avatar.rotation.y,
	)

	avatar.queue_free()


func _test_facing_can_be_turned_off_without_moving_the_body() -> void:
	var avatar := _spawn(41)
	avatar.face_travel_direction = false
	avatar.follow_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(20.0, 0.0)]), 0, 2.0)

	for _frame in TURN_FRAMES:
		avatar.update_to_tick(10)
		await get_tree().process_frame

	_assertions.check_near(
		avatar.rotation.y, 0.0, POSITION_EPSILON, "with facing off the body never turns"
	)
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(2.0, 0.0),
		POSITION_EPSILON,
		"and it still stands exactly where the walker says",
	)

	avatar.queue_free()


func _ground(avatar: PlayerAvatar) -> Vector2:
	return Vector2(avatar.position.x, avatar.position.z)


class FakeMonotonicClock extends RefCounted:
	var now_usec := 0

	func read() -> int:
		return now_usec

	func advance_msec(msec: int) -> void:
		now_usec += msec * 1000
