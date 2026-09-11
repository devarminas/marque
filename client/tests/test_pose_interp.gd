extends RefCounted


const PoseInterp := preload("res://scripts/pose_interp.gd")
const Assertions := preload("res://tests/assertions.gd")

const POSITION_EPSILON := 1.0e-6


func run(assertions: Assertions) -> void:
	_test_single_pose_holds(assertions)
	_test_mid_segment_lerps(assertions)
	_test_past_newest_holds(assertions)
	_test_no_extrapolate_before_oldest(assertions)
	_test_height_lerps(assertions)
	_test_settled_after_stop_is_idle(assertions)
	assertions.finish()


func _test_single_pose_holds(assertions: Assertions) -> void:
	var buf := PoseInterp.new()
	buf.reset_at(10, 1.0, 2.0)
	var sample := buf.sample_xz(10.0 + PoseInterp.INTERP_DELAY_TICKS)
	assertions.check_near(sample.x, 1.0, POSITION_EPSILON, "single pose holds x")
	assertions.check_near(sample.y, 2.0, POSITION_EPSILON, "single pose holds z")
	assertions.check(not buf.moving(10.0 + PoseInterp.INTERP_DELAY_TICKS), "single pose is idle")


func _test_mid_segment_lerps(assertions: Assertions) -> void:
	var buf := PoseInterp.new()
	buf.reset_at(10, 0.0, 0.0)
	buf.push_pose(12, 2.0, 0.0)
	var render := 11.0 + PoseInterp.INTERP_DELAY_TICKS
	var sample := buf.sample_xz(render)
	assertions.check_near(sample.x, 1.0, POSITION_EPSILON, "mid tick lerps halfway")
	assertions.check_near(sample.y, 0.0, POSITION_EPSILON, "mid tick keeps z")
	assertions.check(buf.moving(render), "mid-segment reports moving")


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


func _test_height_lerps(assertions: Assertions) -> void:
	var buf := PoseInterp.new()
	buf.reset_at(10, 0.0, 0.0, 0.0)
	buf.push_pose(12, 0.0, 0.0, 1.0)
	var sample := buf.sample_xyz(11.0 + PoseInterp.INTERP_DELAY_TICKS)
	assertions.check_near(sample.y, 0.5, POSITION_EPSILON, "mid tick lerps height")


func _test_settled_after_stop_is_idle(assertions: Assertions) -> void:
	var buf := PoseInterp.new()
	buf.reset_at(10, 0.0, 0.0)
	buf.push_pose(11, 0.12, 0.0)
	buf.push_pose(12, 0.24, 0.0)
	var settled := 12.0 + PoseInterp.INTERP_DELAY_TICKS
	assertions.check(not buf.moving(settled), "held on newest pose after stop is idle")
	var still_catching_up := 11.5 + PoseInterp.INTERP_DELAY_TICKS
	assertions.check(buf.moving(still_catching_up), "before reaching newest pose still moving")
