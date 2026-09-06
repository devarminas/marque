extends RefCounted

const SessionScript := preload("res://scripts/session.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")

const JOIN_TIMEOUT_MSEC := 20000
const CAST_WAIT_MSEC := 8000
const SPIN_USEC := 20000
const HOLD_MSEC := 1500


var _tree: SceneTree
var _session: SessionScript
var _effects: Array = []


func run(root: Node, session: SessionScript) -> int:
	_tree = root.get_tree()
	_session = session
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

	if not _session.select_player(friendly_id):
		return _fail("could not select friendly dummy %d" % friendly_id)
	print("DEMO select %d friendly" % friendly_id)
	var mana_before := _session.mana_for(_session.own_id()).x
	if mana_before < 0:
		mana_before = 100
	_effects.clear()
	_session.request_cast("heal")
	print("DEMO cast heal %d" % friendly_id)
	if not await _wait_mana_drop(mana_before):
		return _fail("heal did not spend mana on friendly dummy")
	if not await _wait_cast_fx(friendly_id, "heal"):
		return _fail("heal success did not play effect on friendly target %d" % friendly_id)
	var friendly: NpcDummyScript = npcs.get(friendly_id)
	if friendly == null or friendly.get_node_or_null("CastHitFx") == null:
		return _fail("heal flash missing on friendly dummy %d" % friendly_id)
	print("DEMO castfx %d heal" % friendly_id)
	print("DEMO healok %d mana=%d" % [friendly_id, _session.mana_for(_session.own_id()).x])

	if not _session.select_player(hostile_id):
		return _fail("could not select hostile dummy %d" % hostile_id)
	print("DEMO select %d hostile" % hostile_id)
	var hostile_hp_before := _session.hit_points_for(hostile_id).x
	_effects.clear()
	_session.request_cast("fireball")
	print("DEMO cast fireball %d" % hostile_id)
	if not await _wait_cast_fx(hostile_id, "fireball"):
		return _fail("fireball success did not play effect on hostile target %d" % hostile_id)
	var hostile: NpcDummyScript = npcs.get(hostile_id)
	if hostile == null or hostile.get_node_or_null("CastHitFx") == null:
		return _fail("fireball flash missing on hostile dummy %d" % hostile_id)
	print("DEMO castfx %d fireball" % hostile_id)
	if not await _wait_hp(hostile_id, hostile_hp_before, false):
		return _fail("fireball did not lower hostile dummy hp")
	print("DEMO fireballok %d %d" % [hostile_id, _session.hit_points_for(hostile_id).x])

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _on_cast_effect(target_id: int, ability_id: String) -> void:
	_effects.append({"target": target_id, "ability": ability_id})


func _wait_for_join() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var npcs: Dictionary = _session.get("_npcs")
		if _session.own_id() > 0 and npcs.size() >= 2:
			return true
		await _tree.process_frame
	return false


func _wait_hp(id: int, baseline: int, want_raise: bool) -> bool:
	var deadline := Time.get_ticks_msec() + CAST_WAIT_MSEC
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


func _wait_msec(msec: int) -> void:
	await _tree.create_timer(msec / 1000.0).timeout


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
