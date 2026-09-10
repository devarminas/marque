extends RefCounted


const SteerIntegrate := preload("res://scripts/steer_integrate.gd")

const SOFT_ERROR_M := 0.35
const HARD_ERROR_M := 2.0
const SOFT_BLEND_PER_SEC := 12.0

var sim_tick := 0
var sim_x := 0.0
var sim_z := 0.0
var steer := Vector2.ZERO
var disp_x := 0.0
var disp_z := 0.0


func reset_at(tick: int, x: float, z: float) -> void:
	sim_tick = tick
	sim_x = x
	sim_z = z
	steer = Vector2.ZERO
	disp_x = x
	disp_z = z


func apply_wish(dx: float, dz: float) -> void:
	steer = SteerIntegrate.wish_to_steer(dx, dz)


func advance_to_tick(target_tick: int) -> void:
	while sim_tick < target_tick:
		var next := SteerIntegrate.step(sim_x, sim_z, steer)
		sim_x = next.x
		sim_z = next.y
		sim_tick += 1


func soft_pull_display(delta_sec: float) -> void:
	if delta_sec <= 0.0:
		return
	var err := Vector2(disp_x - sim_x, disp_z - sim_z).length()
	if err < SteerIntegrate.STEER_EPSILON:
		disp_x = sim_x
		disp_z = sim_z
		return
	if err >= HARD_ERROR_M:
		disp_x = sim_x
		disp_z = sim_z
		return
	var t := clampf(SOFT_BLEND_PER_SEC * delta_sec, 0.0, 1.0)
	disp_x = lerpf(disp_x, sim_x, t)
	disp_z = lerpf(disp_z, sim_z, t)


func reconcile_server_pose(server_tick: int, x: float, z: float) -> void:
	var target_tick := sim_tick
	if server_tick > target_tick:
		target_tick = server_tick
	sim_x = x
	sim_z = z
	sim_tick = server_tick
	while sim_tick < target_tick:
		var next := SteerIntegrate.step(sim_x, sim_z, steer)
		sim_x = next.x
		sim_z = next.y
		sim_tick += 1
	var err := Vector2(disp_x - sim_x, disp_z - sim_z).length()
	if err >= HARD_ERROR_M or err < SteerIntegrate.STEER_EPSILON:
		disp_x = sim_x
		disp_z = sim_z


func display_xz() -> Vector2:
	return Vector2(disp_x, disp_z)


func sim_xz() -> Vector2:
	return Vector2(sim_x, sim_z)


func moving() -> bool:
	return steer != Vector2.ZERO
