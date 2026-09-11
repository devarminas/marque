extends RefCounted


const LocalMover := preload("res://scripts/local_mover.gd")
const SteerIntegrate := preload("res://scripts/steer_integrate.gd")
const MapCfg := preload("res://scripts/map_cfg.gd")
const NavMesh := preload("res://scripts/nav_mesh.gd")
const Assertions := preload("res://tests/assertions.gd")

const POSITION_EPSILON := 1.0e-3


func run(assertions: Assertions) -> void:
	_test_nil_nav_village_unchanged(assertions)
	_test_wall_blocks_prediction(assertions)
	_test_ramp_raises_height(assertions)
	_test_server_pose_wins_conflict(assertions)
	_test_elevated_jump_lands_local(assertions)
	assertions.finish()


func _test_nil_nav_village_unchanged(assertions: Assertions) -> void:
	var mover := LocalMover.new()
	mover.configure_map(MapCfg.MAP_VILLAGE)
	mover.reset_at(0, 0.0, 0.0)
	mover.apply_wish(1.0, 0.0)
	mover.advance_to_tick(1)
	assertions.check_near(
		mover.sim_xz().x, SteerIntegrate.STEP_DISTANCE, POSITION_EPSILON, "village predict steps"
	)
	assertions.check_near(mover.sim_height(), 0.0, POSITION_EPSILON, "village stays on y=0")
	assertions.check(mover.nav == null, "village prediction has nil nav")


func _test_wall_blocks_prediction(assertions: Assertions) -> void:
	var mover := _arena_mover()
	mover.reset_at(0, 0.0, 0.0)
	mover.apply_wish(1.0, 0.0)
	for _i in 2000:
		var before := mover.sim_xz()
		mover.advance_to_tick(mover.sim_tick + 1)
		if before.is_equal_approx(mover.sim_xz()):
			break
	assertions.check(mover.nav.contains_xz(mover.sim_x, mover.sim_z), "wall walk stays on mesh")
	assertions.check(
		Vector2(mover.sim_x, mover.sim_z).length() < 90.0,
		"wall walk does not tunnel far off arena",
	)


func _test_ramp_raises_height(assertions: Assertions) -> void:
	var mover := _arena_mover()
	var start: Dictionary = mover.nav.height_at(-4.0, 14.0, 0.0)
	assertions.check(bool(start["ok"]), "ramp foot on mesh")
	mover.reset_at(0, -4.0, 14.0, float(start["y"]))
	mover.apply_wish(0.0, 1.0)
	var last_y := mover.sim_height()
	var rose := false
	for _i in 40:
		mover.advance_to_tick(mover.sim_tick + 1)
		assertions.check(mover.nav.contains_xz(mover.sim_x, mover.sim_z), "ramp walk on mesh")
		var want: Dictionary = mover.nav.height_at(mover.sim_x, mover.sim_z, mover.sim_h)
		assertions.check(bool(want["ok"]), "ramp sample ok")
		assertions.check_near(
			mover.sim_height(), float(want["y"]), POSITION_EPSILON, "ramp y tracks HeightAt"
		)
		if mover.sim_height() > last_y + 1e-4:
			rose = true
		last_y = mover.sim_height()
	assertions.check(rose, "ramp prediction raised Y")


func _test_server_pose_wins_conflict(assertions: Assertions) -> void:
	var mover := _arena_mover()
	mover.reset_at(0, 0.0, 0.0)
	mover.apply_wish(1.0, 0.0)
	mover.advance_to_tick(5)
	mover.reconcile_server_pose(5, 1.5, -2.0, 0.4)
	assertions.check_near(mover.sim_xz().x, 1.5, POSITION_EPSILON, "server x wins")
	assertions.check_near(mover.sim_xz().y, -2.0, POSITION_EPSILON, "server z wins")
	assertions.check_near(mover.sim_height(), 0.4, POSITION_EPSILON, "server y wins")


func _test_elevated_jump_lands_local(assertions: Assertions) -> void:
	var mover := _arena_mover()
	var gx := -20.0
	var gz := -50.0
	var sample: Dictionary = mover.nav.height_at(gx, gz, 5.8)
	assertions.check(bool(sample["ok"]), "elevated sample on mesh")
	assertions.check(float(sample["y"]) > 1.0, "elevated ground above floor")
	mover.reset_at(0, gx, gz, float(sample["y"]))
	mover.apply_jump(true)
	assertions.check(mover.airborne(), "elevated jump leaves ground")
	var landed := false
	for _i in 200:
		mover.advance_to_tick(mover.sim_tick + 1)
		if not mover.airborne():
			landed = true
			break
	assertions.check(landed, "elevated jump lands")
	assertions.check_near(
		mover.sim_height(), float(sample["y"]), POSITION_EPSILON, "lands at local HeightAt"
	)
	assertions.check(absf(mover.sim_height()) > 1.0, "does not snap to y=0")


func _arena_mover() -> LocalMover:
	var mover := LocalMover.new()
	var mesh = NavMesh.load_arena()
	mover.configure_prediction(MapCfg.ARENA_HALF_EXTENT, MapCfg.ARENA_FLOOR_Y, mesh)
	return mover
