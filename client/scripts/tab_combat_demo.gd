extends RefCounted

const SessionScript := preload("res://scripts/session.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")

const JOIN_TIMEOUT_MSEC := 20000
const CAST_WAIT_MSEC := 8000
const HIT_WAIT_MSEC := 30000
const SPIN_USEC := 20000
const HOLD_MSEC := 900
const SETTLE_MSEC := 400
const MIN_DISPLACEMENT := 1.5
const STEER_DX := 1.0
const STEER_DZ := 0.0
const CLICK_HEIGHT := 0.8
const SCREENSHOT_WARMUP_FRAMES := 15


var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _prefix: String
var _effects: Array = []


func run(root: Node, session: SessionScript, prefix: String) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_prefix = prefix
	_session.cast_effect_played.connect(_on_cast_effect)

	if not await _wait_for_join():
		return _fail("no welcome with two practice npcs after %dms" % JOIN_TIMEOUT_MSEC)

	print("DEMO joined %d" % _session.own_id())
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

	await _capture(1)

	if not _session.select_player(hostile_id):
		return _fail("could not select hostile dummy %d" % hostile_id)
	print("DEMO select %d hostile" % hostile_id)
	var mana_before_fire := _session.mana_for(_session.own_id()).x
	if mana_before_fire < 0:
		mana_before_fire = 100
	var hostile_hp_before := _session.hit_points_for(hostile_id).x
	_effects.clear()
	_session.request_cast("fireball")
	print("DEMO cast fireball %d" % hostile_id)
	if not await _wait_mana_drop(mana_before_fire):
		return _fail("fireball did not spend mana")
	if not await _wait_cast_fx(hostile_id, "fireball"):
		return _fail("fireball success did not play effect on hostile %d" % hostile_id)
	var hostile: NpcDummyScript = npcs.get(hostile_id)
	if hostile == null or hostile.get_node_or_null("CastHitFx") == null:
		return _fail("fireball flash missing on hostile dummy %d" % hostile_id)
	print("DEMO castfx %d fireball" % hostile_id)
	if not await _wait_hp(hostile_id, hostile_hp_before, false):
		return _fail("fireball did not lower hostile dummy hp")
	print("DEMO fireballok %d %d mana=%d" % [
		hostile_id,
		_session.hit_points_for(hostile_id).x,
		_session.mana_for(_session.own_id()).x,
	])
	await _capture(2)

	if not _session.select_player(friendly_id):
		return _fail("could not select friendly dummy %d" % friendly_id)
	print("DEMO select %d friendly" % friendly_id)
	var mana_before_heal := _session.mana_for(_session.own_id()).x
	if mana_before_heal < 0:
		mana_before_heal = 100
	var friendly_hp_before := _session.hit_points_for(friendly_id).x
	if friendly_hp_before < 0 or friendly_hp_before >= 100:
		return _fail("friendly dummy hp %d needs to be wounded for heal proof" % friendly_hp_before)
	_effects.clear()
	_session.request_cast("heal")
	print("DEMO cast heal %d" % friendly_id)
	if not await _wait_mana_drop(mana_before_heal):
		return _fail("heal did not spend mana on friendly dummy")
	if not await _wait_cast_fx(friendly_id, "heal"):
		return _fail("heal success did not play effect on friendly %d" % friendly_id)
	var friendly: NpcDummyScript = npcs.get(friendly_id)
	if friendly == null or friendly.get_node_or_null("CastHitFx") == null:
		return _fail("heal flash missing on friendly dummy %d" % friendly_id)
	print("DEMO castfx %d heal" % friendly_id)
	if not await _wait_hp(friendly_id, friendly_hp_before, true):
		return _fail("heal did not raise friendly dummy hp")
	print("DEMO healok %d %d mana=%d" % [
		friendly_id,
		_session.hit_points_for(friendly_id).x,
		_session.mana_for(_session.own_id()).x,
	])
	await _capture(3)

	var attack_hp_before := _session.hit_points_for(hostile_id).x
	if not await _right_click_npc(hostile_id):
		return _fail("could not right-click hostile dummy %d" % hostile_id)
	print("DEMO rightclick %d hostile" % hostile_id)
	if _session.selected_player_id() != hostile_id:
		return _fail(
			"hostile right-click did not select %d, got %d"
			% [hostile_id, _session.selected_player_id()]
		)
	if not await _wait_hp(hostile_id, attack_hp_before, false):
		return _fail("hostile dummy hp never dropped after right-click attack")
	print("DEMO attackok %d %d" % [hostile_id, _session.hit_points_for(hostile_id).x])
	await _capture(4)

	var avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	if avatar == null:
		return _fail("no local avatar after join")
	var start := Vector2(avatar.position.x, avatar.position.z)
	print("DEMO pos 1 %d %f %f" % [_session.own_id(), start.x, start.y])
	var deadline := Time.get_ticks_msec() + HOLD_MSEC
	while Time.get_ticks_msec() < deadline:
		_session.request_move(STEER_DX, STEER_DZ)
		await _wait_msec(100)
	_session.request_move(0.0, 0.0)
	await _wait_msec(SETTLE_MSEC)
	var end := Vector2(avatar.position.x, avatar.position.z)
	print("DEMO pos 2 %d %f %f" % [_session.own_id(), end.x, end.y])
	var travelled := start.distance_to(end)
	if travelled < MIN_DISPLACEMENT:
		return _fail("displacement %f below %f after steer" % [travelled, MIN_DISPLACEMENT])
	print("DEMO move_displacement %f" % travelled)
	await _capture(5)

	print("DEMO done")
	return 0


func _on_cast_effect(target_id: int, ability_id: String) -> void:
	_effects.append({"target": target_id, "ability": ability_id})


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


func _wait_hp(id: int, baseline: int, want_raise: bool) -> bool:
	var deadline := Time.get_ticks_msec() + (HIT_WAIT_MSEC if not want_raise else CAST_WAIT_MSEC)
	while Time.get_ticks_msec() < deadline:
		var hp := _session.hit_points_for(id).x
		if want_raise and hp > baseline:
			return true
		if not want_raise and hp < baseline and hp >= 0:
			return true
		await _tree.create_timer(SPIN_USEC / 1_000_000.0).timeout
	return false


func _wait_mana_drop(baseline: int) -> bool:
	var deadline := Time.get_ticks_msec() + CAST_WAIT_MSEC
	while Time.get_ticks_msec() < deadline:
		var mana := _session.mana_for(_session.own_id()).x
		if mana >= 0 and mana < baseline:
			return true
		await _tree.create_timer(SPIN_USEC / 1_000_000.0).timeout
	return false


func _wait_cast_fx(target_id: int, ability_id: String) -> bool:
	var deadline := Time.get_ticks_msec() + CAST_WAIT_MSEC
	while Time.get_ticks_msec() < deadline:
		for entry: Variant in _effects:
			var row: Dictionary = entry
			if int(row.get("target", 0)) == target_id and String(row.get("ability", "")) == ability_id:
				return true
		await _tree.create_timer(SPIN_USEC / 1_000_000.0).timeout
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
	await _tree.create_timer(msec / 1000.0).timeout


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
