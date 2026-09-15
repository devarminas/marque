extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const DemoNpcCapture := preload("res://scripts/demo_npc_capture.gd")
const DemoAdminGive := preload("res://scripts/demo_admin_give.gd")

const REQUIRED_IMPS := 5
const CLICK_HEIGHT := 0.8
const SCREENSHOT_WARMUP_FRAMES := 15
const JOIN_TIMEOUT_MSEC := 25000
const STEP_TIMEOUT_MSEC := 45000
const HOLD_MSEC := 800
const CLASS_ID := "knight"

const KNIGHT_KIT := [
	"plate_helm",
	"plate_chest",
	"plate_legs",
	"sword",
	"shield",
]


var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _prefix: String


func run(root: Node, session: SessionScript, prefix: String) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_prefix = prefix

	if not await _wait_for_join():
		return _fail(
			"need own id and %d imps after %dms" % [REQUIRED_IMPS, JOIN_TIMEOUT_MSEC]
		)
	print("DEMO joined %d" % _session.own_id())

	var giver := DemoAdminGive.new()
	var give_err: String = await giver.grant(
		_session, _tree, KNIGHT_KIT, JOIN_TIMEOUT_MSEC
	)
	if not give_err.is_empty():
		return _fail(give_err)
	if not await _equip_knight_kit():
		return 1
	print("DEMO class %s" % _session.active_class_id())

	if not await _capture(1):
		return 1

	if not await _mid_chase_capture():
		return 1

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _wait_for_join() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.own_id() > 0 and _count_imps() >= REQUIRED_IMPS:
			return true
		await _tree.process_frame
	return false


func _equip_knight_kit() -> bool:
	var indices: PackedInt32Array = _session.get("_bag_indices")
	if indices.is_empty():
		_fail("knight kit never arrived in the bag after /give")
		return false
	for slot: int in indices:
		_session.request_equip(slot)
		await _tree.process_frame
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.active_class_id() == CLASS_ID:
			return true
		await _tree.process_frame
	_fail("worn set never activated knight")
	return false


func _mid_chase_capture() -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	var attacked := false
	while Time.get_ticks_msec() < deadline:
		if await _maybe_respawn():
			pass
		if not attacked:
			var imp_id := _nearest_living_imp()
			if imp_id > 0 and _session.select_player(imp_id):
				if not await _right_click_npc(imp_id):
					_session.request_attack(imp_id)
				print("DEMO attack %d" % imp_id)
				attacked = true
		if _any_imp_chasing():
			print("DEMO midchase")
			return await _capture(2)
		await _tree.process_frame
	return _fail_bool("no mid-chase NPC walking or has_path before timeout")


func _any_imp_chasing() -> bool:
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body.kind != NpcDummyScript.KindImp:
			continue
		if body.is_walking() or body.has_path():
			return true
	return false


func _maybe_respawn() -> bool:
	var hp := _session.hit_points_for(_session.own_id())
	if hp.x != 0:
		return false
	print("DEMO death")
	_session.request_respawn()
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		hp = _session.hit_points_for(_session.own_id())
		if hp.x > 0:
			print("DEMO respawn %d" % hp.x)
			return true
		await _tree.process_frame
	_fail("respawn never restored hp")
	return false


func _right_click_npc(npc_id: int) -> bool:
	var npcs: Dictionary = _session.get("_npcs")
	var body: NpcDummyScript = npcs.get(npc_id)
	if body == null:
		return false
	var camera := _root.get_viewport().get_camera_3d()
	if camera == null:
		return false
	var world_pos := body.global_position + Vector3(0, CLICK_HEIGHT, 0)
	var screen := camera.unproject_position(world_pos)
	var picker := _root.get_node_or_null("GroundPicker") as GroundPickerScript
	if picker == null:
		return false
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	press.position = screen
	press.global_position = screen
	_root.get_viewport().push_input(press)
	await _tree.process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_RIGHT
	release.pressed = false
	release.position = screen
	release.global_position = screen
	_root.get_viewport().push_input(release)
	await _tree.process_frame
	await _tree.physics_frame
	return true


func _count_imps() -> int:
	var n := 0
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body.kind == NpcDummyScript.KindImp:
			n += 1
	return n


func _nearest_living_imp() -> int:
	var avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	if avatar == null:
		return 0
	var best_id := 0
	var best_dist := INF
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body.kind != NpcDummyScript.KindImp:
			continue
		var hp := _session.hit_points_for(id)
		if hp.x == 0:
			continue
		var d := Vector2(avatar.position.x, avatar.position.z).distance_to(
			Vector2(body.position.x, body.position.z)
		)
		if d < best_dist:
			best_dist = d
			best_id = id
	return best_id


func _capture(index: int) -> bool:
	for _frame in SCREENSHOT_WARMUP_FRAMES:
		await RenderingServer.frame_post_draw
	var path := "%s_%d.png" % [_prefix, index]
	var image := _root.get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("screenshot failed to save to %s: %d" % [path, error])
		return false
	print("DEMO shot %d %s" % [index, path])
	DemoNpcCapture.dump(_session)
	return true


func _wait_msec(msec: int) -> void:
	var deadline := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline:
		await _tree.process_frame


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	return 1


func _fail_bool(reason: String) -> bool:
	print("DEMO FAIL %s" % reason)
	return false
