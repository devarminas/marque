extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const DemoAdminGive := preload("res://scripts/demo_admin_give.gd")

const JOIN_TIMEOUT_MSEC := 20000
const CAST_WAIT_MSEC := 12000
const SPIN_USEC := 20000
const HOLD_MSEC := 900
const SETTLE_MSEC := 400
const CAST_RANGE_SLACK := 6.0
const APPROACH_TIMEOUT_MSEC := 8000
const SCREENSHOT_WARMUP_FRAMES := 15

const MAGE_KIT := [
	"cloth_hood",
	"cloth_robe",
	"cloth_skirt",
	"staff",
]


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
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		print("DEMO npc %d %s %s %f %f" % [id, body.kind, body.faction, body.position.x, body.position.z])
		if body.kind != NpcDummyScript.KindDummy:
			continue
		if body.faction == NpcDummyScript.FactionFriendly:
			friendly_id = id
	if friendly_id == 0:
		return _fail("missing friendly practice dummy after join")

	await _capture(1)

	if not _session.select_player(friendly_id):
		return _fail("could not select friendly dummy %d" % friendly_id)
	print("DEMO select %d friendly" % friendly_id)
	if not await _close_in_for_cast(friendly_id, CAST_RANGE_SLACK):
		return _fail(
			"could not close to within %.1f of friendly %d for heal" % [CAST_RANGE_SLACK, friendly_id]
		)
	_session.request_move(0.0, 0.0)
	await _wait_msec(SETTLE_MSEC)
	if not _session.select_player(friendly_id) or _session.selected_player_id() != friendly_id:
		return _fail("friendly practice dummy %d was not selected for heal" % friendly_id)

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
	await _capture(2)

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _close_in_for_cast(npc_id: int, max_dist: float) -> bool:
	var avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	var npcs: Dictionary = _session.get("_npcs")
	var body: NpcDummyScript = npcs.get(npc_id)
	if avatar == null or body == null:
		return false
	var here := Vector2(avatar.position.x, avatar.position.z)
	var there := Vector2(body.position.x, body.position.z)
	if here.distance_to(there) <= max_dist:
		print("DEMO inrange %d %f" % [npc_id, here.distance_to(there)])
		return true
	var wish := (there - here).normalized()
	print("DEMO approach %d %f %f" % [npc_id, wish.x, wish.y])
	var deadline := Time.get_ticks_msec() + APPROACH_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		_session.request_move(wish.x, wish.y)
		await _wait_msec(100)
		here = Vector2(avatar.position.x, avatar.position.z)
		there = Vector2(body.position.x, body.position.z)
		if here.distance_to(there) <= max_dist:
			_session.request_move(0.0, 0.0)
			print("DEMO inrange %d %f" % [npc_id, here.distance_to(there)])
			return true
	_session.request_move(0.0, 0.0)
	return false


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
			await _wait_msec(SETTLE_MSEC)
			return true
		await _tree.process_frame
	_fail("worn set never activated mage")
	return false


func _on_cast_effect(target_id: int, ability_id: String) -> void:
	_effects.append({"target": target_id, "ability": ability_id})


func _wait_for_join() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.own_id() > 0 and _has_friendly_dummy():
			return true
		await _tree.process_frame
	return false


func _has_friendly_dummy() -> bool:
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body == null or body.kind != NpcDummyScript.KindDummy:
			continue
		if body.faction == NpcDummyScript.FactionFriendly:
			return true
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
