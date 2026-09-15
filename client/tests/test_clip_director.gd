extends RefCounted

const ArtContract := preload("res://scripts/art_contract.gd")
const Assertions := preload("res://tests/assertions.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const ClipDirector := preload("res://scripts/clip_director.gd")
const GearLook := preload("res://scripts/gear_look.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")
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


func _test_every_weapon_has_an_attack_period(assertions: Assertions) -> void:
	var periods := WeaponDefs.load_attack_period_ticks()
	for weapon in ["unarmed", "sword", "staff", "bow", "imp_claw"]:
		assertions.check(periods.get(weapon, 0) > 0, "weapons.json gives %s a positive attack period, got %s" % [weapon, periods.get(weapon)])
