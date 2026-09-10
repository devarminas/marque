extends RefCounted


const LocalMover := preload("res://scripts/local_mover.gd")
const SteerIntegrate := preload("res://scripts/steer_integrate.gd")
const Assertions := preload("res://tests/assertions.gd")

const POSITION_EPSILON := 1.0e-6


func run(assertions: Assertions) -> void:
	_test_predict_moves_without_pose(assertions)
	_test_halt_clears_sticky_immediately(assertions)
	_test_reconcile_hard_snaps_large_error(assertions)
	_test_reconcile_keeps_sim_on_server_pose(assertions)
	_test_jump_predicts_height(assertions)
	_test_mid_air_jump_ignored_locally(assertions)
	_test_jump_while_walking(assertions)
	assertions.finish()


func _test_predict_moves_without_pose(assertions: Assertions) -> void:
	var mover := LocalMover.new()
	mover.reset_at(10, 0.0, 0.0)
	mover.apply_wish(1.0, 0.0)
	mover.advance_to_tick(11)
	var sim := mover.sim_xz()
	assertions.check_near(sim.x, SteerIntegrate.STEP_DISTANCE, POSITION_EPSILON, "predict steps 0.12 without pose")
	assertions.check_near(sim.y, 0.0, POSITION_EPSILON, "predict keeps z")
	assertions.check(mover.moving(), "sticky wish reports moving")


func _test_halt_clears_sticky_immediately(assertions: Assertions) -> void:
	var mover := LocalMover.new()
	mover.reset_at(0, 0.0, 0.0)
	mover.apply_wish(0.0, 1.0)
	mover.advance_to_tick(1)
	mover.apply_wish(0.0, 0.0)
	assertions.check(not mover.moving(), "zero wish clears sticky")
	var before := mover.sim_xz()
	mover.advance_to_tick(5)
	var after := mover.sim_xz()
	assertions.check_near(after.x, before.x, POSITION_EPSILON, "halt stops further x motion")
	assertions.check_near(after.y, before.y, POSITION_EPSILON, "halt stops further z motion")


func _test_reconcile_hard_snaps_large_error(assertions: Assertions) -> void:
	var mover := LocalMover.new()
	mover.reset_at(10, 0.0, 0.0)
	mover.apply_wish(0.0, 0.0)
	mover.disp_x = 5.0
	mover.disp_z = 0.0
	mover.reconcile_server_pose(10, 0.0, 0.0)
	var disp := mover.display_xz()
	assertions.check_near(disp.x, 0.0, POSITION_EPSILON, "hard reconcile snaps display x")
	assertions.check_near(disp.y, 0.0, POSITION_EPSILON, "hard reconcile snaps display z")
	var sim := mover.sim_xz()
	assertions.check_near(sim.x, 0.0, POSITION_EPSILON, "forced mispredict sim matches server")
	assertions.check_near(sim.y, 0.0, POSITION_EPSILON, "forced mispredict sim z matches server")


func _test_reconcile_keeps_sim_on_server_pose(assertions: Assertions) -> void:
	var mover := LocalMover.new()
	mover.reset_at(5, 1.0, 2.0)
	mover.apply_wish(0.0, 0.0)
	mover.reconcile_server_pose(5, 4.0, 6.0, 0.25)
	var sim := mover.sim_xz()
	assertions.check_near(sim.x, 4.0, POSITION_EPSILON, "server pose wins sim x")
	assertions.check_near(sim.y, 6.0, POSITION_EPSILON, "server pose wins sim z")
	assertions.check_near(mover.sim_height(), 0.25, POSITION_EPSILON, "server pose wins sim height")


func _test_jump_predicts_height(assertions: Assertions) -> void:
	var mover := LocalMover.new()
	mover.reset_at(0, 0.0, 0.0)
	mover.apply_jump(true)
	assertions.check(mover.airborne(), "jump leaves grounded")
	mover.advance_to_tick(1)
	var want_vy := SteerIntegrate.JUMP_SPEED - SteerIntegrate.GRAVITY * SteerIntegrate.TICK_DURATION_SEC
	var want_h := want_vy * SteerIntegrate.TICK_DURATION_SEC
	assertions.check_near(mover.sim_height(), want_h, POSITION_EPSILON, "first tick rises")
	var landed := false
	mover.advance_to_tick(200)
	if not mover.airborne() and is_equal_approx(mover.sim_height(), 0.0):
		landed = true
	assertions.check(landed, "jump lands back on ground")


func _test_mid_air_jump_ignored_locally(assertions: Assertions) -> void:
	var mover := LocalMover.new()
	mover.reset_at(0, 0.0, 0.0)
	mover.apply_jump(true)
	mover.advance_to_tick(1)
	var before := mover.sim_vy
	mover.apply_jump(true)
	assertions.check_near(mover.sim_vy, before, POSITION_EPSILON, "mid-air jump does not refresh vy")


func _test_jump_while_walking(assertions: Assertions) -> void:
	var mover := LocalMover.new()
	mover.reset_at(0, 0.0, 0.0)
	mover.apply_wish(1.0, 0.0)
	mover.apply_jump(true)
	mover.advance_to_tick(1)
	assertions.check_near(mover.sim_xz().x, SteerIntegrate.STEP_DISTANCE, POSITION_EPSILON, "walk+jump steps x")
	assertions.check(mover.sim_height() > 0.0, "walk+jump is airborne")
