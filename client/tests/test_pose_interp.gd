extends RefCounted


const PoseInterp := preload("res://scripts/pose_interp.gd")
const Assertions := preload("res://tests/assertions.gd")

const POSITION_EPSILON := 1.0e-6


func run(assertions: Assertions) -> void:
	_test_single_pose_holds(assertions)
	_test_mid_segment_lerps(assertions)
	_test_past_newest_holds(assertions)
	_test_no_extrapolate_before_oldest(assertions)
	assertions.finish()


func _test_single_pose_holds(assertions: Assertions) -> void:
	var buf := PoseInterp.new()
	buf.reset_at(10, 1.0, 2.0)
	var sample := buf.sample_xz(10.0 + PoseInterp.INTERP_DELAY_TICKS)
	assertions.check_near(sample.x, 1.0, POSITION_EPSILON, "single pose holds x")
	assertions.check_near(sample.y, 2.0, POSITION_EPSILON, "single pose holds z")
	assertions.check(not buf.moving(), "single pose is idle")


func _test_mid_segment_lerps(assertions: Assertions) -> void:
	var buf := PoseInterp.new()
	buf.reset_at(10, 0.0, 0.0)
	buf.push_pose(12, 2.0, 0.0)
	var sample := buf.sample_xz(11.0 + PoseInterp.INTERP_DELAY_TICKS)
	assertions.check_near(sample.x, 1.0, POSITION_EPSILON, "mid tick lerps halfway")
	assertions.check_near(sample.y, 0.0, POSITION_EPSILON, "mid tick keeps z")
	assertions.check(buf.moving(), "distinct poses report moving")


func _test_past_newest_holds(assertions: Assertions) -> void:
	var buf := PoseInterp.new()
	buf.reset_at(10, 0.0, 0.0)
	buf.push_pose(12, 2.0, 4.0)
	var sample := buf.sample_xz(20.0 + PoseInterp.INTERP_DELAY_TICKS)
	assertions.check_near(sample.x, 2.0, POSITION_EPSILON, "past newest holds x")
	assertions.check_near(sample.y, 4.0, POSITION_EPSILON, "past newest holds z")


func _test_no_extrapolate_before_oldest(assertions: Assertions) -> void:
	var buf := PoseInterp.new()
	buf.reset_at(10, 5.0, 7.0)
	buf.push_pose(14, 9.0, 7.0)
	var sample := buf.sample_xz(0.0 + PoseInterp.INTERP_DELAY_TICKS)
	assertions.check_near(sample.x, 5.0, POSITION_EPSILON, "before oldest clamps to oldest x")
	assertions.check_near(sample.y, 7.0, POSITION_EPSILON, "before oldest clamps to oldest z")
