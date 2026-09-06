extends RefCounted

const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")

const JOIN_TIMEOUT_MSEC := 20000
const HOLD_MSEC := 900
const SETTLE_MSEC := 400
const MIN_DISPLACEMENT := 1.5
const STEER_DX := 1.0
const STEER_DZ := 0.0
const USEC_PER_MSEC := 1000
const SCREENSHOT_WARMUP_FRAMES := 15

var _tree: SceneTree
var _session: SessionScript
var _prefix: String


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
	var start := Vector2(avatar.position.x, avatar.position.z)
	print("DEMO pos 1 %d %f %f" % [_session.own_id(), start.x, start.y])
	await _capture(1)

	var deadline := Time.get_ticks_msec() + HOLD_MSEC
	while Time.get_ticks_msec() < deadline:
		_session.request_move(STEER_DX, STEER_DZ)
		await _wait_msec(100)
	_session.request_move(0.0, 0.0)
	await _wait_msec(SETTLE_MSEC)

	var end := Vector2(avatar.position.x, avatar.position.z)
	print("DEMO pos 2 %d %f %f" % [_session.own_id(), end.x, end.y])
	await _capture(2)
	var travelled := start.distance_to(end)
	if travelled < MIN_DISPLACEMENT:
		return _fail("displacement %f below %f after steer" % [travelled, MIN_DISPLACEMENT])
	print("DEMO move_displacement %f" % travelled)
	print("DEMO done")
	return 0


func _wait_joined() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.own_id() > 0:
			return true
		await _tree.process_frame
	return false


func _capture(index: int) -> void:
	if _prefix.is_empty():
		return
	for _i in SCREENSHOT_WARMUP_FRAMES:
		await _tree.process_frame
	var path := "%s_%d.png" % [_prefix, index]
	var img := _tree.root.get_viewport().get_texture().get_image()
	img.save_png(path)
	print("DEMO shot %d %s" % [index, path])


func _wait_msec(msec: int) -> void:
	var usec := msec * USEC_PER_MSEC
	var start := Time.get_ticks_usec()
	while Time.get_ticks_usec() - start < usec:
		await _tree.process_frame


func _fail(message: String) -> int:
	printerr("DEMO FAIL: %s" % message)
	return 1
