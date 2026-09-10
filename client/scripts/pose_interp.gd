extends RefCounted


const SteerIntegrate := preload("res://scripts/steer_integrate.gd")

const BUFFER_POSES := 8
const INTERP_DELAY_TICKS := 2.0

var _poses: Array = []


func reset_at(tick: int, x: float, z: float) -> void:
	_poses = [{"tick": tick, "x": x, "z": z}]


func push_pose(tick: int, x: float, z: float) -> void:
	var kept: Array = []
	for entry in _poses:
		if int(entry["tick"]) < tick:
			kept.append(entry)
	kept.append({"tick": tick, "x": x, "z": z})
	while kept.size() > BUFFER_POSES:
		kept.pop_front()
	_poses = kept


func sample_xz(render_tick: float) -> Vector2:
	if _poses.is_empty():
		return Vector2.ZERO
	var target := render_tick - INTERP_DELAY_TICKS
	if _poses.size() == 1:
		return Vector2(float(_poses[0]["x"]), float(_poses[0]["z"]))
	var oldest: Dictionary = _poses[0]
	var newest: Dictionary = _poses[_poses.size() - 1]
	if target <= float(oldest["tick"]):
		return Vector2(float(oldest["x"]), float(oldest["z"]))
	if target >= float(newest["tick"]):
		return Vector2(float(newest["x"]), float(newest["z"]))
	for i in range(1, _poses.size()):
		var a: Dictionary = _poses[i - 1]
		var b: Dictionary = _poses[i]
		var ta := float(a["tick"])
		var tb := float(b["tick"])
		if target > tb:
			continue
		if is_equal_approx(ta, tb):
			return Vector2(float(b["x"]), float(b["z"]))
		var u := (target - ta) / (tb - ta)
		return Vector2(
			lerpf(float(a["x"]), float(b["x"]), u),
			lerpf(float(a["z"]), float(b["z"]), u),
		)
	return Vector2(float(newest["x"]), float(newest["z"]))


func moving() -> bool:
	if _poses.size() < 2:
		return false
	var a: Dictionary = _poses[_poses.size() - 2]
	var b: Dictionary = _poses[_poses.size() - 1]
	return (
		Vector2(float(b["x"]) - float(a["x"]), float(b["z"]) - float(a["z"])).length()
		>= SteerIntegrate.MIN_PATH_LENGTH
	)
