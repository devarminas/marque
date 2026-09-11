extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")

const JOIN_TIMEOUT_MSEC := 20000
const WALL_TIMEOUT_MSEC := 25000
const RAMP_TRAVEL_TIMEOUT_MSEC := 35000
const RAMP_CLIMB_MSEC := 2500
const JUMP_TIMEOUT_MSEC := 8000
const STILL_SAMPLES := 5
const STILL_EPS := 0.025
const MIN_WALL_TRAVEL := 8.0
const MAX_WALL_X := 40.0
const RAMP_X := -4.0
const RAMP_Z := 14.0
const RAMP_ARRIVE := 0.6
const MIN_RAMP_RISE := 0.35
const MIN_JUMP_RISE := 0.3
const LAND_EPS := 0.08
const HOLD_POLL_MSEC := 100
const SETTLE_MSEC := 300
const USEC_PER_MSEC := 1000
const SCREENSHOT_WARMUP_FRAMES := 15

var _tree: SceneTree
var _session: SessionScript
var _prefix: String
var _shot := 0


func run(root: Node, session: SessionScript, prefix: String) -> int:
	_tree = root.get_tree()
	_session = session
	_prefix = prefix

	if not await _wait_joined():
		return _fail("no welcome after %dms" % JOIN_TIMEOUT_MSEC)
	print("DEMO joined %d" % _session.own_id())

	var avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	if avatar == null:
		return _fail("no local avatar after join")

	var spawn := avatar.position
	print("DEMO pos 1 %d %f %f %f" % [_session.own_id(), spawn.x, spawn.y, spawn.z])
	await _capture()

	var wall_end := await _steer_until_blocked(1.0, 0.0, WALL_TIMEOUT_MSEC)
	var wall_travel := Vector2(spawn.x, spawn.z).distance_to(Vector2(wall_end.x, wall_end.z))
	if wall_travel < MIN_WALL_TRAVEL:
		return _fail("wall travel %f below %f" % [wall_travel, MIN_WALL_TRAVEL])
	if wall_end.x > MAX_WALL_X:
		return _fail("tunneled past wall to x=%f" % wall_end.x)
	print(
		"DEMO wall_blocked %f %f travel %f"
		% [wall_end.x, wall_end.z, wall_travel]
	)
	print("DEMO pos 2 %d %f %f %f" % [_session.own_id(), wall_end.x, wall_end.y, wall_end.z])
	await _capture()

	if not await _steer_to(RAMP_X, RAMP_Z, RAMP_ARRIVE, RAMP_TRAVEL_TIMEOUT_MSEC):
		return _fail("never reached ramp foot (%.1f, %.1f)" % [RAMP_X, RAMP_Z])
	await _wait_msec(SETTLE_MSEC)
	var ramp_start := avatar.position
	print(
		"DEMO ramp_start %f %f %f"
		% [ramp_start.x, ramp_start.y, ramp_start.z]
	)
	print(
		"DEMO pos 3 %d %f %f %f"
		% [_session.own_id(), ramp_start.x, ramp_start.y, ramp_start.z]
	)
	await _capture()

	var climb_deadline := Time.get_ticks_msec() + RAMP_CLIMB_MSEC
	while Time.get_ticks_msec() < climb_deadline:
		_session.request_move(0.0, 1.0)
		await _wait_msec(HOLD_POLL_MSEC)
	_session.request_move(0.0, 0.0)
	await _wait_msec(SETTLE_MSEC)
	var ramp_end := avatar.position
	var rise := ramp_end.y - ramp_start.y
	if rise < MIN_RAMP_RISE:
		return _fail("ramp rise %f below %f (start_y=%f end_y=%f)" % [
			rise, MIN_RAMP_RISE, ramp_start.y, ramp_end.y
		])
	print("DEMO ramp_rise %f start_y %f end_y %f" % [rise, ramp_start.y, ramp_end.y])
	print(
		"DEMO pos 4 %d %f %f %f"
		% [_session.own_id(), ramp_end.x, ramp_end.y, ramp_end.z]
	)
	await _capture()

	var ground_y := avatar.position.y
	print("DEMO jump_start_y %f" % ground_y)
	_session.request_move(0.0, 0.0, true)
	await _wait_msec(HOLD_POLL_MSEC)
	_session.request_move(0.0, 0.0)

	var peak_y := ground_y
	var left_ground := false
	var landed := false
	var jump_deadline := Time.get_ticks_msec() + JUMP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < jump_deadline:
		var y := avatar.position.y
		if y > peak_y:
			peak_y = y
		if y > ground_y + MIN_JUMP_RISE * 0.5:
			left_ground = true
		if left_ground and y <= ground_y + LAND_EPS:
			landed = true
			break
		await _tree.process_frame
	if not left_ground:
		return _fail("jump never rose (peak_y=%f start_y=%f)" % [peak_y, ground_y])
	if not landed:
		return _fail("jump never landed (peak_y=%f y=%f)" % [peak_y, avatar.position.y])
	var land_y := avatar.position.y
	var jump_rise := peak_y - ground_y
	if jump_rise < MIN_JUMP_RISE:
		return _fail("jump rise %f below %f" % [jump_rise, MIN_JUMP_RISE])
	print("DEMO jump_peak_y %f" % peak_y)
	print("DEMO jump_land_y %f" % land_y)
	print(
		"DEMO pos 5 %d %f %f %f"
		% [_session.own_id(), avatar.position.x, land_y, avatar.position.z]
	)
	await _capture()
	print("DEMO done")
	return 0


func _steer_until_blocked(dx: float, dz: float, timeout_msec: int) -> Vector3:
	var avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	var last := Vector2(avatar.position.x, avatar.position.z)
	var still := 0
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		_session.request_move(dx, dz)
		await _wait_msec(HOLD_POLL_MSEC)
		var cur := Vector2(avatar.position.x, avatar.position.z)
		if cur.distance_to(last) < STILL_EPS:
			still += 1
			if still >= STILL_SAMPLES:
				_session.request_move(0.0, 0.0)
				await _wait_msec(SETTLE_MSEC)
				return avatar.position
		else:
			still = 0
		last = cur
	_session.request_move(0.0, 0.0)
	await _wait_msec(SETTLE_MSEC)
	return avatar.position


func _steer_to(tx: float, tz: float, arrive: float, timeout_msec: int) -> bool:
	var avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		var pos := avatar.position
		var wish := Vector2(tx - pos.x, tz - pos.z)
		if wish.length() <= arrive:
			_session.request_move(0.0, 0.0)
			return true
		wish = wish.normalized()
		_session.request_move(wish.x, wish.y)
		await _wait_msec(HOLD_POLL_MSEC)
	_session.request_move(0.0, 0.0)
	return false


func _wait_joined() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.own_id() > 0:
			return true
		await _tree.process_frame
	return false


func _capture() -> void:
	_shot += 1
	if _prefix.is_empty():
		return
	for _i in SCREENSHOT_WARMUP_FRAMES:
		await _tree.process_frame
	var path := "%s_%d.png" % [_prefix, _shot]
	var img := _tree.root.get_viewport().get_texture().get_image()
	img.save_png(path)
	print("DEMO shot %d %s" % [_shot, path])


func _wait_msec(msec: int) -> void:
	var usec := msec * USEC_PER_MSEC
	var start := Time.get_ticks_usec()
	while Time.get_ticks_usec() - start < usec:
		await _tree.process_frame


func _fail(message: String) -> int:
	printerr("DEMO FAIL: %s" % message)
	return 1
