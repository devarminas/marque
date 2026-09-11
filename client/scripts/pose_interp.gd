extends RefCounted


const SteerIntegrate := preload("res://scripts/steer_integrate.gd")

const BUFFER_POSES := 8
const INTERP_DELAY_TICKS := 2.0

var _poses: Array = []


func reset_at(tick: int, x: float, z: float, height: float = 0.0) -> void:
	_poses = [{"tick": tick, "x": x, "y": height, "z": z}]


func push_pose(tick: int, x: float, z: float, height: float = 0.0) -> void:
	var kept: Array = []
	for entry in _poses:
		if int(entry["tick"]) < tick:
			kept.append(entry)
	kept.append({"tick": tick, "x": x, "y": height, "z": z})
	while kept.size() > BUFFER_POSES:
		kept.pop_front()
	_poses = kept


func sample_xz(render_tick: float) -> Vector2:
	var p := sample_xyz(render_tick)
	return Vector2(p.x, p.z)


func sample_xyz(render_tick: float) -> Vector3:
	if _poses.is_empty():
		return Vector3.ZERO
	var target := render_tick - INTERP_DELAY_TICKS
	if _poses.size() == 1:
		return _entry_xyz(_poses[0])
	var oldest: Dictionary = _poses[0]
	var newest: Dictionary = _poses[_poses.size() - 1]
	if target <= float(oldest["tick"]):
		return _entry_xyz(oldest)
	if target >= float(newest["tick"]):
		return _entry_xyz(newest)
	for i in range(1, _poses.size()):
		var a: Dictionary = _poses[i - 1]
		var b: Dictionary = _poses[i]
		var ta := float(a["tick"])
		var tb := float(b["tick"])
		if target > tb:
			continue
		if is_equal_approx(ta, tb):
			return _entry_xyz(b)
		var u := (target - ta) / (tb - ta)
		return Vector3(
			lerpf(float(a["x"]), float(b["x"]), u),
			lerpf(float(a["y"]), float(b["y"]), u),
			lerpf(float(a["z"]), float(b["z"]), u),
		)
	return _entry_xyz(newest)


func moving(render_tick: float = -1.0) -> bool:
	if _poses.size() < 2:
		return false
	# Once the delayed sample sits on/after the newest pose, the remote has
	# settled (stop pose) — do not keep walking just because the prior step moved.
	if render_tick >= 0.0:
		var target := render_tick - INTERP_DELAY_TICKS
		var newest: Dictionary = _poses[_poses.size() - 1]
		if target >= float(newest["tick"]):
			return false
		var segment := _segment_containing(target)
		if segment.is_empty():
			return false
		var a: Dictionary = segment["a"]
		var b: Dictionary = segment["b"]
		return (
			Vector2(float(b["x"]) - float(a["x"]), float(b["z"]) - float(a["z"])).length()
			>= SteerIntegrate.MIN_PATH_LENGTH
		)
	var prev: Dictionary = _poses[_poses.size() - 2]
	var last: Dictionary = _poses[_poses.size() - 1]
	return (
		Vector2(float(last["x"]) - float(prev["x"]), float(last["z"]) - float(prev["z"])).length()
		>= SteerIntegrate.MIN_PATH_LENGTH
	)


func _segment_containing(target: float) -> Dictionary:
	if _poses.size() < 2:
		return {}
	if target <= float(_poses[0]["tick"]):
		return {}
	for i in range(1, _poses.size()):
		var a: Dictionary = _poses[i - 1]
		var b: Dictionary = _poses[i]
		if target > float(b["tick"]):
			continue
		return {"a": a, "b": b}
	return {}


func _entry_xyz(entry: Dictionary) -> Vector3:
	return Vector3(float(entry["x"]), float(entry["y"]), float(entry["z"]))
