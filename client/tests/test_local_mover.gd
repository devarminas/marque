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
	mover.reconcile_server_pose(5, 4.0, 6.0)
	var sim := mover.sim_xz()
	assertions.check_near(sim.x, 4.0, POSITION_EPSILON, "server pose wins sim x")
	assertions.check_near(sim.y, 6.0, POSITION_EPSILON, "server pose wins sim z")
