extends RefCounted

const SessionScript := preload("res://scripts/session.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")

const JOIN_TIMEOUT_MSEC := 20000
const HIT_WAIT_MSEC := 30000
const SPIN_USEC := 20000
const HOLD_MSEC := 1500
const CLICK_HEIGHT := 0.8


var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _refuses: Array = []


func run(root: Node, session: SessionScript) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_session.attack_refused.connect(
		func(id: int, reason: String) -> void:
			_refuses.append({"player": id, "reason": reason})
	)

	if not await _wait_for_join():
		return _fail("no welcome with two practice npcs after %dms" % JOIN_TIMEOUT_MSEC)

	print("DEMO joined %d" % _session.own_id())
	if not await _equip_mage_kit():
		return 1
	var npcs: Dictionary = _session.get("_npcs")
	var friendly_id := 0
	var hostile_id := 0
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		print("DEMO npc %d %s %s %f %f" % [id, body.kind, body.faction, body.position.x, body.position.z])
		if body.faction == NpcDummyScript.FactionFriendly:
			friendly_id = id
		elif body.faction == NpcDummyScript.FactionHostile:
			hostile_id = id
	if friendly_id == 0 or hostile_id == 0:
		return _fail("missing friendly or hostile dummy after join")

	_refuses.clear()
	if not await _right_click_npc(friendly_id):
		return _fail("could not right-click friendly dummy %d" % friendly_id)
	print("DEMO rightclick %d friendly" % friendly_id)
	await _wait_msec(400)
	if _session.selected_player_id() != friendly_id:
		return _fail(
			"friendly right-click did not select %d, got %d"
			% [friendly_id, _session.selected_player_id()]
		)
	if _refuses.is_empty():
		return _fail("friendly right-click did not refuse attack")
	if _refuses[0]["reason"] != "wrong_target":
		return _fail("friendly refuse reason %s, want wrong_target" % _refuses[0]["reason"])
	print("DEMO refuse %d wrong_target" % friendly_id)

	var hostile_hp_before := _session.hit_points_for(hostile_id).x
	if not await _right_click_npc(hostile_id):
		return _fail("could not right-click hostile dummy %d" % hostile_id)
	print("DEMO rightclick %d hostile" % hostile_id)
	if _session.selected_player_id() != hostile_id:
		return _fail(
			"hostile right-click did not select %d, got %d"
			% [hostile_id, _session.selected_player_id()]
		)
	if not await _wait_hp_drop(hostile_id, hostile_hp_before):
		return _fail("hostile dummy hp never dropped after right-click attack")
	print("DEMO attackok %d %d" % [hostile_id, _session.hit_points_for(hostile_id).x])

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _equip_mage_kit() -> bool:
	var indices: PackedInt32Array = _session.get("_bag_indices")
	if indices.is_empty():
		_fail("mage join kit never arrived in the bag")
		return false
	for slot: int in indices:
		_session.request_equip(slot)
		await _tree.process_frame
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.active_class_id() == "mage":
			print("DEMO class mage")
			return true
		await _tree.process_frame
	_fail("worn set never activated mage")
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


func _wait_for_join() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var npcs: Dictionary = _session.get("_npcs")
		if _session.own_id() > 0 and npcs.size() >= 2:
			return true
		await _tree.process_frame
	return false


func _wait_hp_drop(id: int, baseline: int) -> bool:
	var deadline := Time.get_ticks_msec() + HIT_WAIT_MSEC
	while Time.get_ticks_msec() < deadline:
		var hp := _session.hit_points_for(id).x
		if hp >= 0 and hp < baseline:
			return true
		await _tree.create_timer(SPIN_USEC / 1_000_000.0).timeout
	return false


func _wait_msec(msec: int) -> void:
	await _tree.create_timer(msec / 1000.0).timeout


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
