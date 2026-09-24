extends Node3D


const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")
const CharacterVisual := preload("res://scripts/character_visual.gd")
const Assertions := preload("res://tests/assertions.gd")

const TICK_MS := 100
const POSITION_EPSILON := 1.0e-5
const YAW_EPSILON := 0.0175
const TURN_FRAMES := 40
const LABEL_CLEARANCE := 0.05
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
	_test_the_body_is_the_prototype_humanoid()
	_test_a_vanished_body_draws_magenta()
	_test_present_at_places_and_toggles_walk_anim()
	_test_a_swing_plays_the_swing_clip()
	_test_two_avatars_do_not_share_state()
	_test_an_unmoved_avatar_idles()
	await _test_the_body_turns_to_face_its_direction_of_travel()
	await _test_target_facing_is_rate_limited_and_yields_to_travel()
	await _test_facing_can_be_turned_off_without_moving_the_body()

	_finished = true


func _spawn(id: int) -> PlayerAvatar:
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	avatar.configure(id, TICK_MS)
	_remote_players.add_child(avatar)
	return avatar


func _clip(action: String) -> String:
	return "proto/" + CharacterVisual.contract().clip_for(action, "")


func _test_scene_instantiates_and_configures() -> void:
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	_assertions.check(avatar != null, "player_avatar.tscn instantiates")
	_assertions.check(avatar is Node3D, "its root is a Node3D that carries a world transform")
	_assertions.check(avatar.get_script() != null, "its root script compiled and is attached")
	_assertions.check(avatar.player_id == 0, "an unconfigured avatar has no player id")

	avatar.configure(7, TICK_MS)
	_assertions.check(avatar.player_id == 7, "configure() records the player id")

	_remote_players.add_child(avatar)
	_assertions.check(avatar.get_parent() == _remote_players, "it parents under the RemotePlayers container")

	avatar.teleport_to(3.0, -4.0)
	_assertions.check_position_near(
		Vector2(avatar.position.x, avatar.position.z),
		Vector2(3.0, -4.0),
		POSITION_EPSILON,
		"teleport_to() places it on the ground plane",
	)
	_assertions.check_near(avatar.position.y, avatar.ground_y, POSITION_EPSILON, "its feet sit at ground_y")
	avatar.queue_free()


func _test_the_body_is_the_prototype_humanoid() -> void:
	var avatar := _spawn(8)
	var contract := CharacterVisual.contract()
	var body := avatar.get_node_or_null("Body") as Node3D
	_assertions.check(
		body != null and body.scene_file_path == contract.variants["human"].glb,
		"Body instances %s, got \"%s\"" % [contract.variants["human"].glb, "" if body == null else body.scene_file_path],
	)
	_assertions.check(
		body != null and body.transform.basis.z.z < 0.0,
		"the +Z-authored body is turned to face the avatar's -Z forward",
	)
	var skeleton := avatar.get_node_or_null("Body/Rig/Skeleton3D") as Skeleton3D
	_assertions.check(
		skeleton != null and skeleton.get_bone_count() == contract.bones.size(),
		"the rig carries the %d contract bones, got %d" % [contract.bones.size(), 0 if skeleton == null else skeleton.get_bone_count()],
	)
	if skeleton == null:
		avatar.queue_free()
		return

	var top := 0.0
	for region: String in contract.regions:
		var mesh := skeleton.get_node_or_null("region_" + region) as MeshInstance3D
		_assertions.check(mesh != null and mesh.visible, "a bare avatar shows region_%s" % region)
		if mesh == null:
			continue
		top = maxf(top, mesh.get_aabb().end.y)
		_assertions.check(
			mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
			"region_%s casts a shadow" % region,
		)
		var material := mesh.get_active_material(0)
		_assertions.check(
			material != null and not ("shading_mode" in material and material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED),
			"region_%s has a lit material" % region,
		)
	for item: String in contract.pieces:
		var piece := skeleton.get_node_or_null(item) as MeshInstance3D
		_assertions.check(piece != null and not piece.visible, "a bare avatar hides the %s piece" % item)
		if piece != null:
			top = maxf(top, piece.get_aabb().end.y)

	var hp_label := avatar.get_node_or_null("HpLabel") as Label3D
	_assertions.check(
		hp_label != null and hp_label.position.y >= top + LABEL_CLEARANCE,
		"the HP label at %.2f clears the tallest head or helm at %.3f" % [0.0 if hp_label == null else hp_label.position.y, top],
	)

	var visual := avatar.visual()
	_assertions.check(visual != null and visual.variant == "human", "a human CharacterVisual drives the body")
	_assertions.check_near(skeleton.motion_scale, 1.0, 1.0e-6, "the human rig keeps motion_scale 1")
	var animation := avatar.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_assertions.check(
		animation != null and animation.root_node == NodePath("../Body"),
		"the AnimationPlayer drives the Body rig",
	)
	for action in ["idle", "walk", "swing"]:
		_assertions.check(
			animation != null and animation.has_animation(_clip(action)),
			"the %s clip %s is in the proto library" % [action, _clip(action)],
		)
	var fallback := avatar.get_node_or_null("MissingBody") as MeshInstance3D
	_assertions.check(fallback != null and not fallback.visible, "a healthy body keeps the magenta fallback hidden")
	avatar.queue_free()


func _test_a_vanished_body_draws_magenta() -> void:
	print("  (the ERROR lines below are fail-closed paths under test)")
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	var body := avatar.get_node("Body")
	avatar.remove_child(body)
	body.queue_free()
	avatar.configure(61, TICK_MS)
	_remote_players.add_child(avatar)

	var fallback := avatar.get_node_or_null("MissingBody") as MeshInstance3D
	_assertions.check(fallback != null and fallback.visible, "a vanished body shows the magenta fallback")
	var material := fallback.get_active_material(0) if fallback != null else null
	var albedo := Color(0.0, 0.0, 0.0, 0.0)
	if material != null and "albedo_color" in material:
		albedo = material.albedo_color
	_assertions.check(
		albedo.is_equal_approx(Color(0.95, 0.08, 0.85, 1.0)),
		"the fallback is the palette's magenta, not a default white, got %s" % albedo,
	)
	avatar.present_at(1.0, 1.0, true)
	_assertions.check(avatar.visual().current_clip().is_empty(), "and a bodiless visual plays nothing")
	avatar.queue_free()


func _test_present_at_places_and_toggles_walk_anim() -> void:
	var avatar := _spawn(1)
	avatar.teleport_to(0.0, 0.0)
	avatar.present_at(3.0, -1.0, true)
	_assertions.check_position_near(_ground(avatar), Vector2(3.0, -1.0), POSITION_EPSILON, "present_at places the body")
	var animation := avatar.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_assertions.check(
		animation != null and animation.current_animation == _clip("walk"),
		"walking present_at plays %s, got \"%s\"" % [_clip("walk"), "" if animation == null else animation.current_animation],
	)
	_assertions.check_near(animation.speed_scale, 1.0, 1.0e-4, "at walk speed the walk clip plays at speed 1")

	avatar.present_at(3.0, -1.0, false)
	_assertions.check(
		animation != null and animation.current_animation == _clip("idle"),
		"idle present_at plays %s, got \"%s\"" % [_clip("idle"), "" if animation == null else animation.current_animation],
	)
	avatar.queue_free()


func _test_a_swing_plays_the_swing_clip() -> void:
	var avatar := _spawn(2)
	var animation := avatar.get_node("AnimationPlayer") as AnimationPlayer
	avatar.swing("sword")
	_assertions.check(
		animation.current_animation == _clip("swing"),
		"a sword swing plays %s, got \"%s\"" % [_clip("swing"), animation.current_animation],
	)
	var contract := CharacterVisual.contract()
	var period := 4 * TICK_MS / 1000.0
	_assertions.check_near(
		animation.speed_scale,
		maxf(1.0, contract.clip_length(contract.clip_for("swing", "")) / period),
		1.0e-4,
		"at the sword attack period of %.2f s" % period,
	)
	avatar.queue_free()


func _test_two_avatars_do_not_share_state() -> void:
	var first := _spawn(11)
	var second := _spawn(12)
	first.present_at(2.0, 0.0, true)
	second.present_at(0.0, -2.0, false)
	first.apply_equipment(PackedStringArray(["helmet"]), PackedStringArray(["plate_helm"]))

	_assertions.check(first.player_id == 11 and second.player_id == 12, "ids stay distinct")
	_assertions.check_position_near(_ground(first), Vector2(2.0, 0.0), POSITION_EPSILON, "the first avatar is east")
	_assertions.check_position_near(_ground(second), Vector2(0.0, -2.0), POSITION_EPSILON, "the second is north")
	_assertions.check(
		first.visual().current_clip() != second.visual().current_clip(),
		"one walks while the other idles",
	)
	_assertions.check(
		first.visual().shown_pieces() == PackedStringArray(["plate_helm"]) and second.visual().shown_pieces().is_empty(),
		"and a helm on one is not on the other",
	)
	first.queue_free()
	second.queue_free()


func _test_an_unmoved_avatar_idles() -> void:
	var avatar := _spawn(51)
	var animation := avatar.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_assertions.check(
		animation != null and animation.current_animation == _clip("idle"),
		"an unmoved avatar idles on %s, got \"%s\"" % [_clip("idle"), "" if animation == null else animation.current_animation],
	)
	avatar.queue_free()


func _test_the_body_turns_to_face_its_direction_of_travel() -> void:
	var avatar := _spawn(31)
	_assertions.check(avatar.face_travel_direction, "facing is on by default")

	avatar.teleport_to(0.0, 0.0)
	for _frame in TURN_FRAMES:
		avatar.present_at(2.0, 0.0, true)
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, -PI * 0.5)),
		0.0,
		YAW_EPSILON,
		"walking east settles the body at a yaw of -90 degrees (yaw %.4f rad)" % avatar.rotation.y,
	)

	for _frame in TURN_FRAMES:
		avatar.present_at(2.0, 2.0, true)
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, PI)),
		0.0,
		YAW_EPSILON,
		"walking toward +Z settles the body at a yaw of 180 degrees (yaw %.4f rad)" % avatar.rotation.y,
	)

	var arrived_yaw: float = avatar.rotation.y
	for _frame in TURN_FRAMES:
		avatar.present_at(2.0, 2.0, false)
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, arrived_yaw)),
		0.0,
		YAW_EPSILON,
		"on halt it holds its heading rather than snapping to a default (yaw %.4f rad)" % avatar.rotation.y,
	)
	avatar.queue_free()


func _test_target_facing_is_rate_limited_and_yields_to_travel() -> void:
	var avatar := _spawn(32)
	avatar.teleport_to(0.0, 0.0)
	avatar.face_target(Vector3(4.0, 0.0, 0.0))
	await get_tree().process_frame
	var halfway := avatar.rotation.y
	_assertions.check(
		absf(halfway) > 0.0 and absf(halfway) < PI * 0.5,
		"target turn is gradual mid-turn (yaw %.4f)" % halfway,
	)
	for _frame in TURN_FRAMES:
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, -PI * 0.5)), 0.0, YAW_EPSILON,
		"target facing settles at literal east yaw -90 degrees",
	)

	avatar.rotation.y = 0.0
	avatar.face_target(Vector3(4.0, 0.0, 0.0))
	for _frame in TURN_FRAMES:
		avatar.present_at(0.0, -2.0, true)
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, 0.0)), 0.0, YAW_EPSILON,
		"while walking the travel heading wins over the target",
	)
	var halted_yaw := avatar.rotation.y
	for _frame in TURN_FRAMES:
		avatar.present_at(0.0, -2.0, false)
		await get_tree().process_frame
	_assertions.check_near(
		absf(angle_difference(avatar.rotation.y, halted_yaw)), 0.0, YAW_EPSILON,
		"halt holds the last travel heading rather than switching to target",
	)
	avatar.queue_free()


func _test_facing_can_be_turned_off_without_moving_the_body() -> void:
	var avatar := _spawn(41)
	avatar.face_travel_direction = false
	avatar.teleport_to(0.0, 0.0)
	for _frame in TURN_FRAMES:
		avatar.present_at(2.0, 0.0, true)
		avatar.face_target(Vector3(0.0, 0.0, -4.0))
		await get_tree().process_frame
	_assertions.check_near(avatar.rotation.y, 0.0, POSITION_EPSILON, "with facing off neither travel nor target turns the body")
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(2.0, 0.0),
		POSITION_EPSILON,
		"and it still stands exactly where present_at put it",
	)
	avatar.queue_free()


func _ground(avatar: PlayerAvatar) -> Vector2:
	return Vector2(avatar.position.x, avatar.position.z)
