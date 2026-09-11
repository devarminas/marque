extends RefCounted


const SteerIntegrate := preload("res://scripts/steer_integrate.gd")
const MapCfg := preload("res://scripts/map_cfg.gd")

const SOFT_ERROR_M := 0.35
const HARD_ERROR_M := 2.0
const SOFT_BLEND_PER_SEC := 12.0

var sim_tick := 0
var sim_x := 0.0
var sim_z := 0.0
var sim_h := 0.0
var sim_vy := 0.0
var steer := Vector2.ZERO
var disp_x := 0.0
var disp_z := 0.0
var disp_h := 0.0
var half_extent := MapCfg.WORLD_HALF_EXTENT
var flat_ground_y := 0.0
var nav = null
var _server_xz_moving := false


func configure_map(map_id: String) -> void:
	half_extent = MapCfg.half_extent(map_id)
	flat_ground_y = MapCfg.ground_y(map_id)
	nav = MapCfg.load_nav(map_id)


func configure_prediction(p_half_extent: float, p_flat_ground_y: float, p_nav = null) -> void:
	half_extent = p_half_extent
	flat_ground_y = p_flat_ground_y
	nav = p_nav


func reset_at(tick: int, x: float, z: float, height = null) -> void:
	sim_tick = tick
	sim_x = x
	sim_z = z
	if height == null:
		sim_h = ground_y_at(x, z)
	else:
		sim_h = float(height)
	sim_vy = 0.0
	steer = Vector2.ZERO
	disp_x = x
	disp_z = z
	disp_h = sim_h
	_server_xz_moving = false


func apply_wish(dx: float, dz: float) -> void:
	steer = SteerIntegrate.wish_to_steer(dx, dz)


func apply_jump(jump: bool) -> void:
	sim_vy = SteerIntegrate.apply_jump_edge(
		sim_h, sim_vy, jump, ground_y_at(sim_x, sim_z)
	)


func advance_to_tick(target_tick: int) -> void:
	while sim_tick < target_tick:
		_step_once()


func soft_pull_display(delta_sec: float) -> void:
	if delta_sec <= 0.0:
		return
	var err := Vector3(disp_x - sim_x, disp_h - sim_h, disp_z - sim_z).length()
	if err < SteerIntegrate.STEER_EPSILON:
		disp_x = sim_x
		disp_z = sim_z
		disp_h = sim_h
		return
	if err >= HARD_ERROR_M:
		disp_x = sim_x
		disp_z = sim_z
		disp_h = sim_h
		return
	var t := clampf(SOFT_BLEND_PER_SEC * delta_sec, 0.0, 1.0)
	disp_x = lerpf(disp_x, sim_x, t)
	disp_z = lerpf(disp_z, sim_z, t)
	disp_h = lerpf(disp_h, sim_h, t)


func reconcile_server_pose(server_tick: int, x: float, z: float, height: float = 0.0) -> void:
	var target_tick := sim_tick
	if server_tick > target_tick:
		target_tick = server_tick
	var ground_delta := Vector2(x - sim_x, z - sim_z).length()
	_server_xz_moving = ground_delta >= SteerIntegrate.MIN_PATH_LENGTH
	sim_x = x
	sim_z = z
	sim_h = height
	var gy := ground_y_at(sim_x, sim_z)
	if SteerIntegrate.grounded(sim_h, 0.0, gy):
		sim_vy = 0.0
	sim_tick = server_tick
	while sim_tick < target_tick:
		_step_once()
	var err := Vector3(disp_x - sim_x, disp_h - sim_h, disp_z - sim_z).length()
	if err >= HARD_ERROR_M or err < SteerIntegrate.STEER_EPSILON:
		disp_x = sim_x
		disp_z = sim_z
		disp_h = sim_h


func display_xz() -> Vector2:
	return Vector2(disp_x, disp_z)


func display_height() -> float:
	return disp_h


func sim_xz() -> Vector2:
	return Vector2(sim_x, sim_z)


func sim_height() -> float:
	return sim_h


func moving() -> bool:
	return steer != Vector2.ZERO or _server_xz_moving


func airborne() -> bool:
	return not SteerIntegrate.grounded(sim_h, sim_vy, ground_y_at(sim_x, sim_z))


func ground_y_at(x: float, z: float, near_y = null) -> float:
	var probe := sim_h if near_y == null else float(near_y)
	if nav != null:
		var sample: Dictionary = nav.height_at(x, z, probe)
		if bool(sample["ok"]):
			return float(sample["y"])
	return flat_ground_y


func _step_once() -> void:
	var gy_here := ground_y_at(sim_x, sim_z)
	var was_grounded := SteerIntegrate.grounded(sim_h, sim_vy, gy_here)
	var next := SteerIntegrate.step(sim_x, sim_z, steer, half_extent, nav)
	if was_grounded:
		var new_y := ground_y_at(next.x, next.y, sim_h)
		var moved := (
			Vector2(next.x - sim_x, next.y - sim_z).length() >= SteerIntegrate.MIN_PATH_LENGTH
		)
		var step_ok := (
			nav == null or absf(new_y - sim_h) <= SteerIntegrate.MAX_NAV_STEP_HEIGHT
		)
		if moved and step_ok:
			sim_x = next.x
			sim_z = next.y
			sim_h = new_y
	else:
		sim_x = next.x
		sim_z = next.y
	var gy := ground_y_at(sim_x, sim_z)
	var vert := SteerIntegrate.step_vertical(sim_h, sim_vy, gy)
	sim_h = vert.x
	sim_vy = vert.y
	sim_tick += 1
