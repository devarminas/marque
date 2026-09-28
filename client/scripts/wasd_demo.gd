extends RefCounted

const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const Facing := preload("res://scripts/facing.gd")

const JOIN_TIMEOUT_MSEC := 20000
const HOLD_MSEC := 900
const SETTLE_MSEC := 400
const MIN_DISPLACEMENT := 1.5
const MIN_WALK_SAMPLE_DISPLACEMENT := 0.25
const STEER_DX := 1.0
const STEER_DZ := 0.0
const YAW_EPSILON := 0.02
const USEC_PER_MSEC := 1000
const SCREENSHOT_WARMUP_FRAMES := 15

var _tree: SceneTree
var _session: SessionScript
var _prefix: String


func run(
	root: Node, session: SessionScript, prefix: String, observe_yaw: bool = false,
	facing_off: bool = false
) -> int:
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

	var yaw_before := avatar.rotation.y
	var target_id := 0
	if observe_yaw:
		if facing_off:
			avatar.face_travel_direction = false
		target_id = _hostile_dummy_id()
		if target_id == 0:
			return _fail("no hostile practice dummy for yaw observation")
		var npcs: Dictionary = _session.get("_npcs")
		var target_body: Node3D = npcs.get(target_id)
		avatar.face_target(target_body.global_position)
		await _tree.process_frame
		var yaw_after_request := avatar.rotation.y
		var target_yaw := Facing.yaw_facing(
			Vector2(
				target_body.global_position.x - avatar.global_position.x,
				target_body.global_position.z - avatar.global_position.z
			)
		)
		print(
			"DEMO yaw target_request target=%d before=%.5f after=%.5f target_yaw=%.5f facing_off=%s"
			% [target_id, yaw_before, yaw_after_request, target_yaw, str(facing_off).to_lower()]
		)
		if facing_off and yaw_after_request != yaw_before:
			return _fail("facing-off target request changed yaw %.8f -> %.8f" % [yaw_before, yaw_after_request])
		if not facing_off and absf(angle_difference(yaw_after_request, target_yaw)) >= absf(angle_difference(yaw_before, target_yaw)):
			return _fail("target-facing request did not turn toward hostile target")

	for _i in 4:
		_session.request_move(STEER_DX, STEER_DZ)
		await _wait_msec(100)

	var walking_pose := Vector2(avatar.position.x, avatar.position.z)
	var yaw_walking := avatar.rotation.y
	var walking_displacement := start.distance_to(walking_pose)
	if observe_yaw:
		print(
			"DEMO yaw walking yaw=%.5f pose=%f,%f displacement=%f wish=%f,%f"
			% [
				yaw_walking, walking_pose.x, walking_pose.y, walking_displacement, STEER_DX, STEER_DZ,
			]
		)
		if walking_displacement < MIN_WALK_SAMPLE_DISPLACEMENT:
			return _fail("yaw walking pose displacement %f below %f" % [walking_displacement, MIN_WALK_SAMPLE_DISPLACEMENT])
		if facing_off:
			if yaw_walking != yaw_before:
				return _fail("facing-off walking changed yaw %.8f -> %.8f" % [yaw_before, yaw_walking])
		else:
			var wanted_yaw := Facing.yaw_facing(Vector2(STEER_DX, STEER_DZ))
			if absf(angle_difference(yaw_walking, wanted_yaw)) > YAW_EPSILON:
				return _fail(
					"walking yaw %.5f does not follow wish yaw %.5f" % [yaw_walking, wanted_yaw]
				)

	var deadline := Time.get_ticks_msec() + HOLD_MSEC - 400
	while Time.get_ticks_msec() < deadline:
		_session.request_move(STEER_DX, STEER_DZ)
		await _wait_msec(100)
	_session.request_move(0.0, 0.0)
	await _wait_msec(SETTLE_MSEC)

	var yaw_halt := avatar.rotation.y
	if observe_yaw:
		print("DEMO yaw halt yaw=%.5f held_from=%.5f" % [yaw_halt, yaw_walking])
		if facing_off:
			if yaw_halt != yaw_before:
				return _fail("facing-off halt changed yaw %.8f -> %.8f" % [yaw_before, yaw_halt])
		elif absf(angle_difference(yaw_halt, yaw_walking)) > YAW_EPSILON:
			return _fail("halt yaw %.5f did not hold walking yaw %.5f" % [yaw_halt, yaw_walking])

	var end := Vector2(avatar.position.x, avatar.position.z)
	print("DEMO pos 2 %d %f %f" % [_session.own_id(), end.x, end.y])
	await _capture(2)
	var travelled := start.distance_to(end)
	if travelled < MIN_DISPLACEMENT:
		return _fail("displacement %f below %f after steer" % [travelled, MIN_DISPLACEMENT])
	print("DEMO move_displacement %f" % travelled)
	print("DEMO wish_ok")
	print("DEMO done")
	return 0


func _hostile_dummy_id() -> int:
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body != null and body.kind == NpcDummyScript.KindDummy and body.faction == NpcDummyScript.FactionHostile:
			return id
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
