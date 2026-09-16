extends RefCounted

const ArtContract := preload("res://scripts/art_contract.gd")
const Assertions := preload("res://tests/assertions.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const ClipDirector := preload("res://scripts/clip_director.gd")
const GearLook := preload("res://scripts/gear_look.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")
const SteerIntegrate := preload("res://scripts/steer_integrate.gd")
const WeaponDefs := preload("res://scripts/weapon_defs.gd")

const WALK_SPEED := 3.0
const EPSILON := 1.0e-4
const SERVER_TICK_SEC := 0.04


func run(assertions: Assertions) -> void:
	var contract := ArtContract.new(ArtContract.read_text(ArtContract.PATH))
	assertions.check(contract.is_valid(), "the art contract parses clean, got %s" % [contract.errors])
	_test_idle_to_walk_to_idle(assertions, contract)
	_test_walk_speed_follows_ground_speed(assertions, contract)
	_test_swing_restarts_and_scales_to_the_attack_period(assertions, contract)
	_test_a_slow_attack_never_slows_the_swing(assertions, contract)
	_test_swing_overrides_walk_then_hands_back(assertions, contract)
	_test_imp_and_player_resolve_the_same_swing_clip(assertions, contract)
	_test_a_jump_launches_then_falls_then_lands(assertions, contract)
	_test_a_step_under_the_enter_height_never_leaves_the_ground(assertions, contract)
	_test_the_air_layer_outranks_walking_and_hands_it_back(assertions, contract)
	_test_an_actor_that_never_elevates_stays_grounded(assertions, contract)
	_test_the_first_jump_tick_clears_the_enter_height_across_the_tick_band(assertions)
	_test_a_cast_winds_up_then_releases(assertions, contract)
	_test_a_cancelled_cast_returns_to_locomotion(assertions, contract)
	_test_an_ability_with_no_row_of_its_own_falls_back(assertions, contract)
	_test_an_instant_cast_leaves_a_pending_channel_alone(assertions, contract)
	_test_every_weapon_has_an_attack_period(assertions)
	assertions.finish()


func _test_idle_to_walk_to_idle(assertions: Assertions, contract: ArtContract) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	var idle := director.advance(0.0)
	assertions.check(idle.clip == contract.clip_for("idle", "") and not idle.restart, "a fresh actor idles, got %s" % idle.clip)
	director.locomote(WALK_SPEED)
	assertions.check(director.advance(0.1).clip == contract.clip_for("walk", ""), "ground speed switches to walk")
	director.locomote(0.0)
	assertions.check(director.advance(0.1).clip == contract.clip_for("idle", ""), "stopping returns to idle")
	assertions.check_near(director.advance(0.1).speed_scale, 1.0, EPSILON, "idle plays at speed 1")


func _test_walk_speed_follows_ground_speed(assertions: Assertions, contract: ArtContract) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.locomote(WALK_SPEED * 0.5)
	assertions.check_near(director.advance(0.0).speed_scale, 0.5, EPSILON, "half the reference speed walks at half speed")
	var imp := ClipDirector.new(contract, WALK_SPEED * contract.motion_scale("imp"))
	imp.locomote(WALK_SPEED)
	assertions.check_near(
		imp.advance(0.0).speed_scale,
		1.0 / contract.motion_scale("imp"),
		EPSILON,
		"an imp at player speed strides faster by its motion scale",
	)


func _test_swing_restarts_and_scales_to_the_attack_period(assertions: Assertions, contract: ArtContract) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	var period := 4 * SERVER_TICK_SEC
	var length := contract.clip_length(contract.clip_for("swing", ""))
	director.swing(period)
	var first := director.advance(0.0)
	assertions.check(first.clip == contract.clip_for("swing", "") and first.restart, "a swing starts the swing clip from its first frame")
	assertions.check_near(first.speed_scale, length / period, EPSILON, "and plays it at clip length over attack period %.2f" % (length / period))
	var mid := director.advance(period * 0.5)
	assertions.check(mid.clip == first.clip and not mid.restart, "halfway through the period it is still swinging without a restart")
	director.swing(period)
	var again := director.advance(0.0)
	assertions.check(again.clip == first.clip and again.restart, "a second swing restarts the clip")
	assertions.check(director.advance(period * 0.9).clip == first.clip, "the restarted swing runs its whole period")
	assertions.check(director.advance(period * 0.2).clip == contract.clip_for("idle", ""), "and hands back to idle once the period is over")


func _test_a_slow_attack_never_slows_the_swing(assertions: Assertions, contract: ArtContract) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.swing(10.0)
	assertions.check_near(director.advance(0.0).speed_scale, 1.0, EPSILON, "a period longer than the clip plays it at speed 1")


func _test_swing_overrides_walk_then_hands_back(assertions: Assertions, contract: ArtContract) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.locomote(WALK_SPEED)
	director.advance(0.0)
	director.swing(0.16)
	assertions.check(director.advance(0.0).clip == contract.clip_for("swing", ""), "a swing outranks walking")
	var after := director.advance(0.2)
	assertions.check(
		after.clip == contract.clip_for("walk", "") and not after.restart,
		"and walking resumes without a restart when it ends, got %s" % after.clip,
	)


func _test_imp_and_player_resolve_the_same_swing_clip(assertions: Assertions, contract: ArtContract) -> void:
	var sets := ClassDefs.load_sets()
	var player := ClipDirector.new(contract, WALK_SPEED)
	player.set_grip(GearLook.resolve(PackedStringArray([GripDefs.GRIP_HAND]), PackedStringArray(["sword"]), contract, sets).grip)
	var imp := ClipDirector.new(contract, WALK_SPEED * contract.motion_scale("imp"))
	imp.set_grip(GearLook.resolve(PackedStringArray(), PackedStringArray(), contract, sets).grip)
	player.swing(0.16)
	imp.swing(0.16)
	var player_clip := player.advance(0.0).clip
	var imp_clip := imp.advance(0.0).clip
	assertions.check(
		not player_clip.is_empty() and player_clip == imp_clip,
		"a sword player and a bare imp resolve the same swing clip, got %s and %s" % [player_clip, imp_clip],
	)


func _test_a_jump_launches_then_falls_then_lands(assertions: Assertions, contract: ArtContract) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.elevate(0.0)
	assertions.check(not director.airborne(), "a grounded actor is not airborne")
	var clips := _fly_a_jump(director, contract)
	assertions.check(
		clips[0] == contract.clip_for("jump_start", ""),
		"the first airborne tick plays jump_start, got %s" % clips[0],
	)
	assertions.check(
		clips.count(contract.clip_for("fall", "")) > 0,
		"the jump reaches fall before it lands, got %s" % [clips],
	)
	var launch_ticks := clips.find(contract.clip_for("fall", ""))
	assertions.check(
		clips.slice(0, launch_ticks).count(contract.clip_for("jump_start", "")) == launch_ticks,
		"with every tick before fall on jump_start, got %s" % [clips.slice(0, launch_ticks)],
	)
	assertions.check(
		clips.slice(launch_ticks).count(contract.clip_for("fall", "")) == clips.size() - launch_ticks,
		"and fall holding from there to the landing, got %s" % [clips.slice(launch_ticks)],
	)
	director.elevate(0.0)
	assertions.check(not director.airborne(), "touching down leaves the air layer")
	assertions.check(
		director.advance(SERVER_TICK_SEC).clip == contract.clip_for("idle", ""),
		"and a standing actor idles again",
	)


func _test_a_step_under_the_enter_height_never_leaves_the_ground(
	assertions: Assertions, contract: ArtContract
) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.locomote(WALK_SPEED)
	var entered := false
	for clearance in [0.0, ClipDirector.AIR_ENTER, 0.05, ClipDirector.AIR_ENTER, 0.0, 0.11, 0.0]:
		director.elevate(clearance)
		entered = entered or director.advance(SERVER_TICK_SEC).clip != contract.clip_for("walk", "")
	assertions.check(
		not entered,
		"stepping up and down below %.2f m keeps walking, never the air layer" % ClipDirector.AIR_ENTER,
	)


func _test_the_air_layer_outranks_walking_and_hands_it_back(
	assertions: Assertions, contract: ArtContract
) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.locomote(WALK_SPEED)
	assertions.check(director.advance(0.0).clip == contract.clip_for("walk", ""), "running along the ground")
	director.elevate(0.5)
	assertions.check(
		director.advance(0.0).clip == contract.clip_for("jump_start", ""),
		"a running jump outranks the walk",
	)
	director.swing(0.16)
	assertions.check(
		director.advance(0.0).clip == contract.clip_for("swing", ""),
		"and a swing still outranks the air layer",
	)
	director.elevate(0.0)
	assertions.check(
		director.advance(0.2).clip == contract.clip_for("walk", ""),
		"landing mid-swing hands straight back to the walk",
	)


func _test_the_first_jump_tick_clears_the_enter_height_across_the_tick_band(assertions: Assertions) -> void:
	for hz: float in [20.0, 25.0, 30.0]:
		var dt := 1.0 / hz
		var rise := (SteerIntegrate.JUMP_SPEED - SteerIntegrate.GRAVITY * dt) * dt
		assertions.check(
			rise > ClipDirector.AIR_ENTER,
			"at %.0f Hz the first jump tick rises %.3f m, over AIR_ENTER %.3f" % [hz, rise, ClipDirector.AIR_ENTER],
		)


func _test_an_actor_that_never_elevates_stays_grounded(
	assertions: Assertions, contract: ArtContract
) -> void:
	var imp := ClipDirector.new(contract, WALK_SPEED * contract.motion_scale("imp"))
	imp.locomote(WALK_SPEED)
	imp.advance(1.0)
	imp.locomote(0.0)
	assertions.check(
		not imp.airborne() and imp.advance(1.0).clip == contract.clip_for("idle", ""),
		"an NPC whose visual never calls elevate can only walk and idle",
	)


func _test_a_cast_winds_up_then_releases(assertions: Assertions, contract: ArtContract) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	var windup := contract.clip_for("cast_windup", "fireball")
	var release := contract.clip_for("cast_release", "fireball")
	director.cast_phase(ClipDirector.PHASE_BEGIN, "fireball")
	assertions.check(director.advance(0.0).clip == windup, "begin starts the windup")
	assertions.check(
		director.advance(contract.clip_length(windup) * 3.0).clip == windup,
		"which loops for as long as the server keeps the cast open",
	)
	director.cast_phase(ClipDirector.PHASE_RESOLVE, "fireball")
	var first := director.advance(0.0)
	assertions.check(
		first.clip == release and first.restart,
		"resolve plays the release from its first frame, got %s" % first.clip,
	)
	assertions.check(
		director.advance(contract.clip_length(release) * 0.5).clip == release,
		"the release runs its own length, not the cast's",
	)
	assertions.check(
		director.advance(contract.clip_length(release)).clip == contract.clip_for("idle", ""),
		"and hands back to idle once, never looping the release",
	)


func _test_a_cancelled_cast_returns_to_locomotion(
	assertions: Assertions, contract: ArtContract
) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.locomote(WALK_SPEED)
	director.cast_phase(ClipDirector.PHASE_BEGIN, "fireball")
	assertions.check(
		director.advance(0.0).clip == contract.clip_for("cast_windup", "fireball"),
		"a cast outranks walking",
	)
	director.cast_phase(ClipDirector.PHASE_CANCEL, "fireball")
	assertions.check(
		director.advance(0.0).clip == contract.clip_for("walk", ""),
		"cancel drops straight back to the walk with no release",
	)
	assertions.check(director.channelling().is_empty(), "and nothing is channelling")


func _test_an_ability_with_no_row_of_its_own_falls_back(
	assertions: Assertions, contract: ArtContract
) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.cast_phase(ClipDirector.PHASE_BEGIN, "heal")
	var windup := director.advance(0.0).clip
	assertions.check(
		windup == contract.clip_for("cast_windup", ""),
		'heal has no cast_windup row, so it resolves through key "", got %s' % windup,
	)
	director.cast_phase(ClipDirector.PHASE_RESOLVE, "heal")
	var release := director.advance(0.0).clip
	assertions.check(
		release == contract.clip_for("cast_release", ""),
		'and its release does the same, got %s' % release,
	)
	assertions.check(
		not windup.is_empty() and not release.is_empty(),
		"neither falls through to an empty clip name",
	)


func _test_an_instant_cast_leaves_a_pending_channel_alone(
	assertions: Assertions, contract: ArtContract
) -> void:
	var director := ClipDirector.new(contract, WALK_SPEED)
	director.cast_phase(ClipDirector.PHASE_BEGIN, "fireball")
	director.cast_phase(ClipDirector.PHASE_RESOLVE, "heal")
	assertions.check(
		director.channelling() == "fireball",
		"an instant resolve with no begin of its own leaves the timed cast pending (ADR 0013)",
	)
	assertions.check(
		director.advance(contract.clip_length(contract.clip_for("cast_release", "heal"))).clip
		== contract.clip_for("cast_windup", "fireball"),
		"so the windup is still there when the instant's release ends",
	)


func _fly_a_jump(director: ClipDirector, contract: ArtContract) -> Array:
	var clips := []
	var height := 0.0
	var vy := SteerIntegrate.apply_jump_edge(height, 0.0, true)
	while true:
		var vert := SteerIntegrate.step_vertical(height, vy)
		height = vert.x
		vy = vert.y
		if height <= 0.0:
			break
		director.elevate(height)
		clips.append(director.advance(SERVER_TICK_SEC).clip)
	return clips


func _test_every_weapon_has_an_attack_period(assertions: Assertions) -> void:
	var periods := WeaponDefs.load_attack_period_ticks()
	for weapon in ["unarmed", "sword", "staff", "bow", "imp_claw"]:
		assertions.check(periods.get(weapon, 0) > 0, "weapons.json gives %s a positive attack period, got %s" % [weapon, periods.get(weapon)])
