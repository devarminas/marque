extends RefCounted


const SteerIntegrate := preload("res://scripts/steer_integrate.gd")

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
# True while server poses are translating us (approach walks clear steer).
var _pose_ground_moving := false


func reset_at(tick: int, x: float, z: float, height: float = 0.0) -> void:
	sim_tick = tick
	sim_x = x
	sim_z = z
	sim_h = height
	sim_vy = 0.0
	steer = Vector2.ZERO
	disp_x = x
	disp_z = z
	disp_h = height
	_pose_ground_moving = false


func apply_wish(dx: float, dz: float) -> void:
	steer = SteerIntegrate.wish_to_steer(dx, dz)


func apply_jump(jump: bool) -> void:
	sim_vy = SteerIntegrate.apply_jump_edge(sim_h, sim_vy, jump)


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
	_pose_ground_moving = ground_delta >= SteerIntegrate.MIN_PATH_LENGTH
	sim_x = x
	sim_z = z
	sim_h = height
	if sim_h <= 0.0:
		sim_h = 0.0
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
	return steer != Vector2.ZERO or _pose_ground_moving


func airborne() -> bool:
	return not SteerIntegrate.grounded(sim_h, sim_vy)


func _step_once() -> void:
	var next := SteerIntegrate.step(sim_x, sim_z, steer)
	sim_x = next.x
	sim_z = next.y
	var vert := SteerIntegrate.step_vertical(sim_h, sim_vy)
	sim_h = vert.x
	sim_vy = vert.y
	sim_tick += 1
