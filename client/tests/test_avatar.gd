extends Node3D

## Tests for [code]scenes/player_avatar.tscn[/code] and its script.
##
## This is the seam the wiring unit attaches to, so the suite drives it exactly
## the way that unit will: instantiate the packed scene, [code]configure()[/code]
## it, parent it under a [code]RemotePlayers[/code] container, and hand it paths.
##
## The container here mirrors the empty [code]RemotePlayers[/code] node authored
## in [code]main.tscn[/code]. Instancing avatars into it in script is the case
## CLAUDE.md's scene-authoring rule allows: how many players are online is
## genuine runtime information.

const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")
const TickClock := preload("res://scripts/tick_clock.gd")
const Assertions := preload("res://tests/assertions.gd")

const TICK_MS := 100
const POSITION_EPSILON := 1.0e-5
## One degree. The turn is damped over frames, so the assertion is convergence,
## not an instantaneous value.
const YAW_EPSILON := 0.0175
## Frames to let the damped turn settle. At the authored 540 deg/s even a slow
## headless frame rate covers a half-turn many times over in this many.
const TURN_FRAMES := 40

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

	# A shadow needs a caster. Unlit geometry casts none, and without one a
	# body on a plane has no readable contact point (NOTES.md, "Color as
	# semantics"). The windowed screenshot check proves the shadow actually
	# lands; this proves the meshes are authored to cast it at all.
	#
	# The rig is the skinned Knight, so the meshes live under its Skeleton3D.
	# A body whose meshes were still the retired blue capsule would have zero
	# of them there.
	var skeleton := avatar.get_node_or_null("Knight/Rig_Medium/Skeleton3D") as Skeleton3D
	_assertions.check(skeleton != null, "the rig's Skeleton3D exists under Knight/Rig_Medium")
	var skinned := 0
	if skeleton != null:
		for node in skeleton.get_children():
			var mesh := node as MeshInstance3D
			if mesh == null:
				continue
			skinned += 1
			_assertions.check(
				mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
				"%s casts a shadow" % mesh.name,
			)
			# Imported glTF meshes carry their own materials, which need not be
			# StandardMaterial3D. Unlit is still checkable on any material that has
			# the property, and an unlit body would cast no shadow: the claim above
			# would then be a lie, so a build that went unlit fails here too.
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

	_assertions.check(avatar.get_node_or_null("Knight") is Node3D, "the Knight rig is instanced")
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
		animation != null and animation.root_node == NodePath("../Knight"),
		"the AnimationPlayer drives the Knight rig",
	)

	avatar.queue_free()


## The avatar's position must be whatever the walker says it is, for any tick,
## with no accumulation of its own.
func _test_position_tracks_the_walker_over_simulated_time() -> void:
	var avatar := _spawn(1)
	avatar.teleport_to(0.0, 0.0)
	# 10 units east at 2 u/s is 5 seconds, which is 50 ticks at 100ms.
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

	# Out of order, then backwards. The position is computed from the tick, not
	# accumulated, so neither can drift it.
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

	# A new path mid-walk replaces the old one outright.
	avatar.follow_path(PackedVector2Array([Vector2(10.0, 0.0), Vector2(10.0, 6.0)]), 200, 3.0)
	avatar.update_to_tick(210)
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(10.0, 3.0),
		POSITION_EPSILON,
		"it walks the replacement path, not the old one",
	)

	avatar.queue_free()


## Each avatar owns its own walker. A shared one would put every player on one
## player's path, which reads as a server bug from the client side.
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


## A freshly spawned avatar has no path yet, and the tick still says what it
## is doing: standing. Idle_A must be playing, not bind pose.
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


## The animation is derived from the tick, not a stored flag: mid-path the
## Knight runs, past the end it settles into the idle cycle, and a rewind
## re-derives the run because nothing was cached.
func _test_walk_animation_follows_the_walker() -> void:
	var avatar := _spawn(2)
	var animation := avatar.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_assertions.check(
		animation != null and animation.current_animation.is_empty(),
		"an avatar with no path plays nothing",
	)

	avatar.follow_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(6.0, 0.0)]), 0, 3.0)
	avatar.update_to_tick(5)
	_assertions.check(
		animation != null and animation.current_animation == PlayerAvatar.WALK_ANIM,
		"a mid-path tick runs %s, got \"%s\""
		% [PlayerAvatar.WALK_ANIM, "" if animation == null else animation.current_animation],
	)
	_assertions.check(
		animation != null and is_equal_approx(animation.speed_scale, PlayerAvatar.WALK_SPEED_SCALE),
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


## With a clock assigned the avatar advances itself, which is how the wiring unit
## uses it: spawn, hand it paths, and never think about frames.
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

	# 15 ticks of monotonic time, no attempt to feed the avatar a tick.
	fake.advance_msec(15 * TICK_MS)
	await get_tree().process_frame
	_assertions.check_position_near(
		_ground(avatar),
		Vector2(3.0, 0.0),
		POSITION_EPSILON,
		"15 ticks of clock time later it has walked 3.0 units on its own",
	)

	avatar.queue_free()


## A Node3D's forward is local -Z, so walking east is a yaw of -90 degrees.
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

	# Turn a corner: the same avatar, now walking north.
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

	# Arrival must not spin it back to a default.
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


## Facing is feel and position is protocol, so switching facing off must not move
## the body by a millimetre.
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


## Duplicated from the tick clock suite rather than shared: it is three lines,
## and a shared fixture between a tree-free suite and a scene suite would be a
## dependency in the direction this project keeps deliberately empty.
class FakeMonotonicClock extends RefCounted:
	var now_usec := 0

	func read() -> int:
		return now_usec

	func advance_msec(msec: int) -> void:
		now_usec += msec * 1000
