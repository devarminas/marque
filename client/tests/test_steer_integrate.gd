extends RefCounted


const SteerIntegrate := preload("res://scripts/steer_integrate.gd")
const Assertions := preload("res://tests/assertions.gd")

const POSITION_EPSILON := 1.0e-6


func run(assertions: Assertions) -> void:
	_test_wish_clears_below_epsilon(assertions)
	_test_wish_normalizes(assertions)
	_test_step_matches_server_distance(assertions)
	_test_step_clamps_world(assertions)
	_test_step_skips_tiny_displacement(assertions)
	assertions.finish()


func _test_wish_clears_below_epsilon(assertions: Assertions) -> void:
	assertions.check(
		SteerIntegrate.wish_to_steer(0.0, 0.0) == Vector2.ZERO,
		"zero wish clears sticky steer",
	)
	assertions.check(
		SteerIntegrate.wish_to_steer(1e-7, 0.0) == Vector2.ZERO,
		"sub-epsilon wish clears sticky steer",
	)


func _test_wish_normalizes(assertions: Assertions) -> void:
	var steer := SteerIntegrate.wish_to_steer(3.0, 4.0)
	assertions.check_near(steer.x, 0.6, POSITION_EPSILON, "wish dx normalizes")
	assertions.check_near(steer.y, 0.8, POSITION_EPSILON, "wish dz normalizes")
	var large := SteerIntegrate.wish_to_steer(100.0, 0.0)
	assertions.check_near(large.x, 1.0, POSITION_EPSILON, "large wish magnitude discarded")
	assertions.check_near(large.y, 0.0, POSITION_EPSILON, "large wish stays on axis")


func _test_step_matches_server_distance(assertions: Assertions) -> void:
	var next := SteerIntegrate.step(0.0, 0.0, Vector2(1.0, 0.0))
	assertions.check_near(next.x, 0.12, POSITION_EPSILON, "east step is WalkSpeed * 0.04")
	assertions.check_near(next.y, 0.0, POSITION_EPSILON, "east step keeps z")


func _test_step_clamps_world(assertions: Assertions) -> void:
	var next := SteerIntegrate.step(128.0, 0.0, Vector2(1.0, 0.0))
	assertions.check_near(next.x, 128.0, POSITION_EPSILON, "clamp at +WorldHalfExtent")
	var west := SteerIntegrate.step(-128.0, 0.0, Vector2(-1.0, 0.0))
	assertions.check_near(west.x, -128.0, POSITION_EPSILON, "clamp at -WorldHalfExtent")


func _test_step_skips_tiny_displacement(assertions: Assertions) -> void:
	var stuck := SteerIntegrate.step(128.0, 0.0, Vector2(1.0, 0.0))
	assertions.check_near(stuck.x, 128.0, POSITION_EPSILON, "bound step does not move")
