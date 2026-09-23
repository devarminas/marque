extends RefCounted

const SessionScript := preload("res://scripts/session.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const DemoAdminGive := preload("res://scripts/demo_admin_give.gd")

const JOIN_TIMEOUT_MSEC := 20000
const HIT_WAIT_MSEC := 30000
const SPIN_USEC := 20000
const HOLD_MSEC := 1500
const CLICK_HEIGHT := 0.8

const MAGE_KIT := [
	"cloth_hood",
	"cloth_robe",
	"cloth_skirt",
	"staff",
]


var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _refuses: Array = []
var _swings: Array = []


func run(root: Node, session: SessionScript, expect_white_miss: bool = false, shot_path: String = "", review: bool = false) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	var net: Node = _session.get("_net")
	net.swing_hit_observed.connect(
		func(id: int, amount: int, crit: bool, miss: bool) -> void:
			_swings.append({"id": id, "amount": amount, "crit": crit, "miss": miss})
	)
	_session.attack_refused.connect(
		func(id: int, reason: String) -> void:
			_refuses.append({"player": id, "reason": reason})
	)

	if not await _wait_for_join():
		return _fail("no welcome with two practice npcs after %dms" % JOIN_TIMEOUT_MSEC)

	print("DEMO joined %d" % _session.own_id())
	var giver := DemoAdminGive.new()
	var give_err: String = await giver.grant(
		_session, _tree, MAGE_KIT, JOIN_TIMEOUT_MSEC
	)
	if not give_err.is_empty():
		return _fail(give_err)
	if not await _equip_mage_kit():
		return 1
	var npcs: Dictionary = _session.get("_npcs")
	var friendly_id := 0
	var hostile_id := 0
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		print("DEMO npc %d %s %s %f %f" % [id, body.kind, body.faction, body.position.x, body.position.z])
		# Practice dummies only — imps and other hostiles must not become the attack target.
		if body.kind != NpcDummyScript.KindDummy:
			continue
		if body.faction == NpcDummyScript.FactionFriendly:
			friendly_id = id
		elif body.faction == NpcDummyScript.FactionHostile:
			hostile_id = id
	if friendly_id == 0 or hostile_id == 0:
		return _fail("missing friendly or hostile practice dummy after join")

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
	# Right-click on a non-hostile practice dummy selects only (ARM-252 talk path).
	# Refuse is proven via the same request_attack gate the headless suite uses.
	_session.request_attack(friendly_id)
	await _tree.process_frame
	if _refuses.is_empty():
		return _fail("friendly attack did not refuse")
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
	if expect_white_miss:
		if not await _wait_swing_miss():
			return _fail("no server swing miss after right-click attack")
		print("DEMO miss %d amount=0 crit=false hp=%d" % [hostile_id, _session.hit_points_for(hostile_id).x])
		if not shot_path.is_empty():
			await RenderingServer.frame_post_draw
			var shot_error := _root.get_viewport().get_texture().get_image().save_png(shot_path)
			if shot_error != OK:
				return _fail("miss screenshot failed: %d" % shot_error)
			print("DEMO missshot %s" % shot_path)
		if review:
			for frame in range(30):
				await RenderingServer.frame_post_draw
				var review_path := "%s-%02d.png" % [shot_path.get_basename(), frame]
				var review_error := _root.get_viewport().get_texture().get_image().save_png(review_path)
				if review_error != OK:
					return _fail("miss review frame failed: %d" % review_error)
				await _wait_msec(1000)
			print("DEMO missframes 30")
		else:
			await _wait_msec(6000)
		if _session.hit_points_for(hostile_id).x != hostile_hp_before:
			return _fail("miss changed dummy hp from %d to %d" % [hostile_hp_before, _session.hit_points_for(hostile_id).x])
		for swing: Dictionary in _swings:
			if swing["id"] == _session.own_id() and (not swing["miss"] or swing["crit"] or swing["amount"] != 0):
				return _fail("white swing was not a miss: %s" % [swing])
		print("DEMO misshp %d unchanged=%d" % [hostile_id, hostile_hp_before])
	else:
		if not await _wait_hp_drop(hostile_id, hostile_hp_before):
			return _fail("hostile dummy hp never dropped after right-click attack")
		print("DEMO attackok %d %d" % [hostile_id, _session.hit_points_for(hostile_id).x])

		var hp_after_first := _session.hit_points_for(hostile_id).x
		await _wait_msec(6000)
		var hp_after_sustain := _session.hit_points_for(hostile_id).x
		if hp_after_sustain <= 0:
			return _fail("hostile dummy died during sustained attack: hp=%d" % hp_after_sustain)
		if hp_after_sustain >= hp_after_first:
			return _fail("hostile dummy hp did not keep falling: %d -> %d" % [hp_after_first, hp_after_sustain])
		print("DEMO immortal %d hp=%d" % [hostile_id, hp_after_sustain])

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _equip_mage_kit() -> bool:
	var indices: PackedInt32Array = _session.get("_bag_indices")
	if indices.is_empty():
		_fail("mage kit never arrived in the bag after /give")
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
		if _session.own_id() > 0 and _has_practice_dummy_pair():
			return true
		await _tree.process_frame
	return false


func _has_practice_dummy_pair() -> bool:
	var npcs: Dictionary = _session.get("_npcs")
	var friendly := false
	var hostile := false
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body == null or body.kind != NpcDummyScript.KindDummy:
			continue
		if body.faction == NpcDummyScript.FactionFriendly:
			friendly = true
		elif body.faction == NpcDummyScript.FactionHostile:
			hostile = true
	return friendly and hostile


func _wait_swing_miss() -> bool:
	var deadline := Time.get_ticks_msec() + HIT_WAIT_MSEC
	while Time.get_ticks_msec() < deadline:
		for swing: Dictionary in _swings:
			if swing["id"] == _session.own_id():
				return swing["miss"] and not swing["crit"] and swing["amount"] == 0
		await _tree.create_timer(SPIN_USEC / 1_000_000.0).timeout
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
