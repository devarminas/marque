extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const CastBarScript := preload("res://scripts/cast_bar.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const DemoAdminGive := preload("res://scripts/demo_admin_give.gd")

const FIREBALL := "fireball"
const MAGE_CLASS := "mage"
const MAGE_KINDS: Array[String] = [
	"cloth_hood",
	"cloth_robe",
	"cloth_skirt",
	"staff",
]

const STEER_DX := 1.0
const STEER_DZ := 0.0
const SCREENSHOT_WARMUP_FRAMES := 15
const JOIN_TIMEOUT_MSEC := 20000
const CLASS_TIMEOUT_MSEC := 15000
const CAST_TIMEOUT_MSEC := 12000
const CASTBAR_TIMEOUT_MSEC := 4000
const COOLDOWN_WAIT_MSEC := 2000
const HOLD_MSEC := 800
const SPIN_USEC := 20000


var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _cast_bar: CastBarScript
var _prefix: String
var _effects: Array = []
var _cast_seen: Array = []


func run(
	root: Node,
	session: SessionScript,
	cast_bar: CastBarScript,
	prefix: String,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_cast_bar = cast_bar
	_prefix = prefix

	_session.cast_effect_played.connect(_on_cast_effect)
	var net: Node = _session.get("net")
	if net != null and net.has_signal("casting_changed"):
		net.casting_changed.connect(_on_casting_changed)

	if not await _wait_until(_world_ready, JOIN_TIMEOUT_MSEC):
		return _fail("no welcome with hostile practice dummy after %dms" % JOIN_TIMEOUT_MSEC)
	print("DEMO joined %d" % _session.own_id())

	var giver := DemoAdminGive.new()
	var give_err: String = await giver.grant(
		_session, _tree, MAGE_KINDS, JOIN_TIMEOUT_MSEC
	)
	if not give_err.is_empty():
		return _fail(give_err)
	if not await _equip_mage():
		return 1
	print("DEMO class %s" % _session.active_class_id())

	var hostile_id := _hostile_dummy_id()
	if hostile_id == 0:
		return _fail("no hostile practice dummy")
	if not _session.select_player(hostile_id):
		return _fail("could not select hostile dummy %d" % hostile_id)
	print("DEMO select %d hostile" % hostile_id)

	if not await _capture(1):
		return 1
	if not await _cast_resolve(hostile_id):
		return 1
	if not await _capture(2):
		return 1

	await _wait_msec(COOLDOWN_WAIT_MSEC)
	if not await _cast_interrupt(hostile_id):
		return 1
	if not await _capture(3):
		return 1

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _world_ready() -> bool:
	return _session.own_id() > 0 and _hostile_dummy_id() > 0


func _equip_mage() -> bool:
	var indices: PackedInt32Array = _session.get("_bag_indices")
	if indices.is_empty():
		_fail("mage kit never arrived in the bag after /give")
		return false
	for slot: int in indices:
		_session.request_equip(slot)
		await _tree.process_frame
	if not await _wait_until(
		func() -> bool:
			return _session.active_class_id() == MAGE_CLASS,
		CLASS_TIMEOUT_MSEC,
	):
		_fail("worn set never activated mage")
		return false
	return true


func _cast_resolve(hostile_id: int) -> bool:
	_effects.clear()
	_cast_seen.clear()
	var mana_before := _session.mana_for(_session.own_id()).x
	if mana_before < 0:
		mana_before = 100
	_session.request_cast(FIREBALL)
	print("DEMO cast %s %d" % [FIREBALL, hostile_id])
	if not await _wait_until(
		func() -> bool:
			return _cast_bar != null and _cast_bar.visible,
		CASTBAR_TIMEOUT_MSEC,
	):
		_fail("cast bar never became visible for resolve cast")
		return false
	print("DEMO castbar %s visible=1" % FIREBALL)
	if not await _wait_cast_fx(hostile_id, FIREBALL):
		_fail("resolve fireball never played cast effect")
		return false
	if not await _wait_until(
		func() -> bool:
			return _cast_bar == null or not _cast_bar.visible,
		CAST_TIMEOUT_MSEC,
	):
		_fail("cast bar stayed visible after resolve")
		return false
	print("DEMO castbar %s visible=0" % FIREBALL)
	var mana_after := _session.mana_for(_session.own_id()).x
	if mana_after >= mana_before:
		_fail("resolve cast did not spend mana (%d -> %d)" % [mana_before, mana_after])
		return false
	print("DEMO castok %s %d mana=%d" % [FIREBALL, hostile_id, mana_after])
	return true


func _cast_interrupt(hostile_id: int) -> bool:
	_effects.clear()
	_cast_seen.clear()
	var mana_before := _session.mana_for(_session.own_id()).x
	_session.request_cast(FIREBALL)
	print("DEMO castinterrupt %s %d" % [FIREBALL, hostile_id])
	if not await _wait_until(
		func() -> bool:
			return _cast_progress() >= 1,
		CASTBAR_TIMEOUT_MSEC,
	):
		_fail("interrupt cast never advanced progress")
		return false
	print("DEMO castbar %s progress=%d" % [FIREBALL, _cast_progress()])
	_session.request_move(STEER_DX, STEER_DZ)
	print("DEMO steer %f %f" % [STEER_DX, STEER_DZ])
	await _tree.create_timer(0.05).timeout
	_session.request_move(0.0, 0.0)
	if not await _wait_until(
		func() -> bool:
			return _cast_bar == null or not _cast_bar.visible,
		CAST_TIMEOUT_MSEC,
	):
		_fail("cast bar stayed visible after interrupt walk")
		return false
	for entry: Variant in _effects:
		var row: Dictionary = entry
		if String(row.get("ability", "")) == FIREBALL:
			_fail("interrupted fireball still played cast effect")
			return false
	var mana_after := _session.mana_for(_session.own_id()).x
	if mana_after >= 0 and mana_before >= 0 and mana_after < mana_before:
		_fail("interrupt charged mana (%d -> %d)" % [mana_before, mana_after])
		return false
	print("DEMO castcancel %s %d" % [FIREBALL, hostile_id])
	return true


func _on_cast_effect(target_id: int, ability_id: String) -> void:
	_effects.append({"target": target_id, "ability": ability_id})
	print("DEMO castfx %d %s" % [target_id, ability_id])


func _on_casting_changed(ability: String, progress: int, total: int) -> void:
	_cast_seen.append({"ability": ability, "progress": progress, "total": total})


func _cast_progress() -> int:
	var best := 0
	for entry: Variant in _cast_seen:
		var row: Dictionary = entry
		if String(row.get("ability", "")) != FIREBALL:
			continue
		best = maxi(best, int(row.get("progress", 0)))
	return best


func _wait_cast_fx(target_id: int, ability_id: String) -> bool:
	var deadline := Time.get_ticks_msec() + CAST_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		for entry: Variant in _effects:
			var row: Dictionary = entry
			if int(row.get("target", 0)) == target_id and String(row.get("ability", "")) == ability_id:
				return true
		await _tree.create_timer(SPIN_USEC / 1_000_000.0).timeout
	return false


func _hostile_dummy_id() -> int:
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body != null and body.kind == NpcDummyScript.KindDummy \
				and body.faction == NpcDummyScript.FactionHostile:
			return id
	return 0


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
	return true


func _wait_until(predicate: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _tree.process_frame
	return false


func _wait_msec(msec: int) -> void:
	await _tree.create_timer(msec / 1000.0).timeout


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
