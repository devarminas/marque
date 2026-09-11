extends Node3D


const PlayerCharacterScript := preload("res://scripts/player_character.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const CameraRigScript := preload("res://scripts/camera_rig.gd")
const LocalMover := preload("res://scripts/local_mover.gd")
const SteerIntegrate := preload("res://scripts/steer_integrate.gd")
const Assertions := preload("res://tests/assertions.gd")

const FOLLOW_FRAMES := 30
const POSITION_EPSILON := 1.0e-5
const HEIGHT_EPSILON := 1.0e-4
const RIG_FOLLOW_EPSILON := 0.15


@onready var _prop: PlayerCharacterScript = $PlayerCharacter

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
	await get_tree().process_frame
	await get_tree().process_frame

	_test_prop_authors_avatar_and_camera()
	await _test_wish_walk_plays_walk_anim_and_camera_follows()
	await _test_approach_pose_stream_walks_then_idles()
	await _test_jump_height_presentation()
	_test_settle_idle()

	if _assertions.failures.is_empty():
		print("PASS: player_character prop mock")
	_assertions.finish()
	_finished = true


func _avatar() -> PlayerAvatarScript:
	return _prop.avatar as PlayerAvatarScript


func _rig() -> CameraRigScript:
	return _prop.camera_rig as CameraRigScript


func _animation() -> AnimationPlayer:
	return _avatar().get_node_or_null("AnimationPlayer") as AnimationPlayer


func _test_prop_authors_avatar_and_camera() -> void:
	_assertions.check(_prop != null, "harness instances props/player_character.tscn")
	_assertions.check(
		_prop.scene_file_path == "res://scenes/props/player_character.tscn",
		"prop scene_file_path is player_character.tscn",
	)
	var avatar := _avatar()
	var rig := _rig()
	_assertions.check(avatar != null and avatar is PlayerAvatarScript, "prop authors Player avatar")
	_assertions.check(rig != null and rig is CameraRigScript, "prop authors CameraRig")
	_assertions.check(rig.target == avatar, "CameraRig target is the prop avatar")
	_assertions.check(
		_prop.camera != null and rig.camera == _prop.camera,
		"CameraRig owns Camera3D on the prop",
	)


func _test_wish_walk_plays_walk_anim_and_camera_follows() -> void:
	var avatar := _avatar()
	var rig := _rig()
	var mover := LocalMover.new()
	mover.reset_at(0, 0.0, 0.0)
	avatar.configure(1)
	avatar.teleport_to(0.0, 0.0)
	rig.global_position = avatar.global_position

	mover.apply_wish(1.0, 0.0)
	mover.advance_to_tick(8)
	mover.soft_pull_display(1.0)
	var ground := mover.display_xz()
	avatar.present_at(ground.x, ground.y, mover.moving(), mover.display_height())

	var animation := _animation()
	_assertions.check(mover.moving(), "wish LocalMover reports moving")
	_assertions.check(
		animation != null and animation.current_animation == PlayerAvatarScript.WALK_ANIM,
		"wish present_at plays walk anim, got \"%s\""
		% ("" if animation == null else animation.current_animation),
	)
	_assertions.check(
		avatar.position.x > POSITION_EPSILON,
		"wish present_at advanced avatar x, got %f" % avatar.position.x,
	)

	var before := rig.global_position.distance_to(avatar.global_position)
	for _frame in FOLLOW_FRAMES:
		await get_tree().process_frame
	var after := rig.global_position.distance_to(avatar.global_position)
	_assertions.check(
		after < before or after <= RIG_FOLLOW_EPSILON,
		"camera rig closed on moving target (%f -> %f)" % [before, after],
	)
	_assertions.check(
		rig.target == avatar,
		"camera rig stays attached to prop avatar while walking",
	)


func _test_approach_pose_stream_walks_then_idles() -> void:
	var avatar := _avatar()
	var mover := LocalMover.new()
	mover.reset_at(0, 0.0, 0.0)
	avatar.teleport_to(0.0, 0.0)
	mover.apply_wish(0.0, 0.0)

	var tick := 1
	var z := 0.0
	var saw_walk := false
	for _step in range(6):
		z += SteerIntegrate.STEP_DISTANCE
		mover.reconcile_server_pose(tick, 0.0, z, 0.0)
		tick += 1
		var ground := mover.display_xz()
		avatar.present_at(ground.x, ground.y, mover.moving(), mover.display_height())
		await get_tree().process_frame
		var animation := _animation()
		if animation != null and animation.current_animation == PlayerAvatarScript.WALK_ANIM:
			saw_walk = true
	_assertions.check(saw_walk, "approach pose stream plays walk anim")
	_assertions.check(mover.moving(), "approach poses keep LocalMover moving mid-stream")

	mover.reconcile_server_pose(tick, 0.0, z, 0.0)
	var settled := mover.display_xz()
	avatar.present_at(settled.x, settled.y, mover.moving(), mover.display_height())
	await get_tree().process_frame
	_assertions.check(not mover.moving(), "identical approach pose clears moving")
	var animation := _animation()
	_assertions.check(
		animation != null and animation.current_animation == PlayerAvatarScript.IDLE_ANIM,
		"approach settle plays idle anim, got \"%s\""
		% ("" if animation == null else animation.current_animation),
	)


func _test_jump_height_presentation() -> void:
	var avatar := _avatar()
	var mover := LocalMover.new()
	mover.reset_at(0, 2.0, 2.0)
	avatar.teleport_to(2.0, 2.0)
	mover.apply_jump(true)
	mover.advance_to_tick(1)
	mover.soft_pull_display(1.0)
	var ground := mover.display_xz()
	var height := mover.display_height()
	avatar.present_at(ground.x, ground.y, mover.moving(), height)
	_assertions.check(height > HEIGHT_EPSILON, "jump predict raises display height")
	_assertions.check_near(
		avatar.position.y,
		avatar.ground_y + height,
		HEIGHT_EPSILON,
		"present_at lifts avatar y for jump",
	)

	mover.advance_to_tick(200)
	mover.soft_pull_display(1.0)
	ground = mover.display_xz()
	height = mover.display_height()
	avatar.present_at(ground.x, ground.y, mover.moving(), height)
	_assertions.check(
		not mover.airborne() and is_equal_approx(height, 0.0),
		"jump lands and clears height",
	)
	_assertions.check_near(
		avatar.position.y,
		avatar.ground_y,
		HEIGHT_EPSILON,
		"landed present_at returns avatar to ground_y",
	)


func _test_settle_idle() -> void:
	var avatar := _avatar()
	var mover := LocalMover.new()
	mover.reset_at(10, avatar.position.x, avatar.position.z)
	mover.apply_wish(0.0, 0.0)
	var ground := mover.display_xz()
	avatar.present_at(ground.x, ground.y, mover.moving(), mover.display_height())
	_assertions.check(not mover.moving(), "zero wish is not moving")
	var animation := _animation()
	_assertions.check(
		animation != null and animation.current_animation == PlayerAvatarScript.IDLE_ANIM,
		"settle idle plays idle anim, got \"%s\""
		% ("" if animation == null else animation.current_animation),
	)
	_assertions.check(
		_rig().target == avatar,
		"camera rig remains attached after settle",
	)
