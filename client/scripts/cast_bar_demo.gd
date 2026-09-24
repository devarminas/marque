extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const CastBarScript := preload("res://scripts/cast_bar.gd")
const HotbarScript := preload("res://scripts/hotbar.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const DemoAdminGive := preload("res://scripts/demo_admin_give.gd")
const AbilityDefs := preload("res://scripts/ability_defs.gd")
const ErrorHudScript := preload("res://scripts/error_hud.gd")

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
const SCREENSHOT_WARMUP_FRAMES := 1
const JOIN_TIMEOUT_MSEC := 20000
const CLASS_TIMEOUT_MSEC := 15000
const CAST_TIMEOUT_MSEC := 12000
const CASTBAR_TIMEOUT_MSEC := 4000
const COOLDOWN_WAIT_MSEC := 6000
const COOLDOWN_READY_GUARD_TICKS := 8
const HOLD_MSEC := 800
const SPIN_USEC := 20000


var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _cast_bar: CastBarScript
var _hotbar: HotbarScript
var _prefix: String
var _effects: Array = []
var _cast_seen: Array = []
var _cast_phases: Array = []
var _refusals: Array = []
var _cooldown_updates: Array = []
var _welcome_cooldowns: Array = []
var _ticks_received := 0
var _sweep_previous_remaining := -1
var _yaw_samples := false


func run(
	root: Node,
	session: SessionScript,
	cast_bar: CastBarScript,
	prefix: String,
	yaw_samples: bool = false,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_cast_bar = cast_bar
	_hotbar = _session.get("hotbar") as HotbarScript
	_prefix = prefix
	_yaw_samples = yaw_samples

	_session.cast_effect_played.connect(_on_cast_effect)
	var net: Node = _session.get("net")
	if net != null and net.has_signal("casting_changed"):
		net.casting_changed.connect(_on_casting_changed)
		net.cast_phase_observed.connect(_on_cast_phase)
		net.server_error.connect(_on_server_error)
		net.cast_cooldown_observed.connect(_on_cast_cooldown)
		net.cooldowns_received.connect(_on_cooldowns_received)
		net.tick_received.connect(_on_tick_received)

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

	if _sweep_demo_requested():
		return await _run_sweep_demo(hostile_id)
	if _oom_demo_requested():
		return await _run_oom_demo(hostile_id)
	if _refusal_demo_requested():
		return await _run_refusal_demo(hostile_id)
	if _cooldown_proof_requested():
		return await _run_cooldown_proof(hostile_id)

	if not await _capture(1):
		return 1
	if not await _cast_resolve(hostile_id):
		return 1
	if not await _capture(2):
		return 1
	if not await _wait_for_ready(FIREBALL):
		return 1
	if not await _cast_interrupt(hostile_id):
		return 1
	if not await _capture(3):
		return 1

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _yaw_advanced(before: float, mid: float, wanted: float) -> bool:
	var start_distance := absf(angle_difference(before, wanted))
	var mid_distance := absf(angle_difference(mid, wanted))
	return absf(angle_difference(before, mid)) > 0.01 and mid_distance < start_distance and mid_distance > 0.01


func _press_ability(ability_id: String) -> void:
	if _hotbar == null:
		_fail("hotbar is unavailable for the demo press")
		return
	for index in HotbarScript.SLOT_COUNT:
		if _hotbar.ability_id_in_slot(index + 1) == ability_id:
			var widgets: Array = _hotbar.call("_slot_widgets")
			var slot: Button = widgets[index]
			slot.pressed.emit()
			print("DEMO hotbar_press slot=%d ability=%s" % [index + 1, ability_id])
			return
	_fail("ability %s has no hotbar slot" % ability_id)


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
	var local_avatar: Node3D = _session.get("_local")
	var yaw_before := local_avatar.rotation.y if _yaw_samples and local_avatar != null else 0.0
	_press_ability(FIREBALL)
	print("DEMO cast %s %d" % [FIREBALL, hostile_id])
	if not await _wait_until(
		func() -> bool:
			return _cast_bar != null and _cast_bar.visible,
		CASTBAR_TIMEOUT_MSEC,
	):
		_fail("cast bar never became visible for resolve cast")
		return false
	print("DEMO castbar %s visible=1" % FIREBALL)
	if _yaw_samples and local_avatar != null:
		for _frame in 4:
			await _tree.process_frame
		var target_body: Node3D = (_session.get("_npcs") as Dictionary).get(hostile_id)
		var wanted_yaw := atan2(
			-(target_body.global_position.x - local_avatar.global_position.x),
			-(target_body.global_position.z - local_avatar.global_position.z),
		)
		if not _yaw_advanced(yaw_before, local_avatar.rotation.y, wanted_yaw):
			return _fail("cast yaw did not turn gradually toward the hostile target")
		print("DEMO yaw cast before=%.5f mid=%.5f" % [yaw_before, local_avatar.rotation.y])
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
	if _yaw_samples and local_avatar != null:
		var target_body: Node3D = (_session.get("_npcs") as Dictionary).get(hostile_id)
		var wanted_yaw := atan2(
			-(target_body.global_position.x - local_avatar.global_position.x),
			-(target_body.global_position.z - local_avatar.global_position.z),
		)
		if absf(angle_difference(local_avatar.rotation.y, wanted_yaw)) >= absf(angle_difference(yaw_before, wanted_yaw)):
			return _fail("cast yaw after resolve was not closer to the target")
		print("DEMO yaw cast after=%.5f" % local_avatar.rotation.y)
	return true


func _cast_interrupt(hostile_id: int) -> bool:
	_effects.clear()
	_cast_seen.clear()
	var mana_before := _session.mana_for(_session.own_id()).x
	_press_ability(FIREBALL)
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


func _sweep_demo_requested() -> bool:
	return OS.get_cmdline_user_args().has("--cast-bar-sweep-demo")


func _run_sweep_demo(hostile_id: int) -> int:
	if not await _cast_resolve(hostile_id):
		return 1
	if not await _wait_for_sweep(FIREBALL, true):
		return 1
	if not await _sweep_observation("appearing", 1):
		return 1
	await _wait_msec(600)
	if not await _sweep_observation("draining", 2):
		return 1
	if not await _sweep_observation("idle", 3):
		return 1
	_cast_phases.clear()
	_press_ability("heal")
	if not await _wait_until(func() -> bool: return _phase_count("heal", "resolve") > 0, CAST_TIMEOUT_MSEC):
		return _fail("heal did not resolve before welcome resync")
	if _session.cooldown_remaining("heal") <= 0:
		return _fail("heal resolve did not anchor its cooldown")
	if not await _reconnect_with_cooldowns():
		return 1
	var welcome_remaining := _snapshot_remaining(_welcome_cooldowns.back(), FIREBALL)
	var resynced_remaining := _session.cooldown_remaining(FIREBALL)
	print("DEMO sweep resync fireball remaining=%d welcome=%d" % [resynced_remaining, welcome_remaining])
	if absi(resynced_remaining - welcome_remaining) > 2:
		return _fail("sweep differs from welcome cooldown by more than two ticks")
	if not await _capture(4):
		return 1
	if not _session.select_player(_hostile_dummy_id()):
		return _fail("could not reselect hostile dummy after sweep reconnect")
	if not await _wait_for_ready(FIREBALL):
		return 1
	var cache: Dictionary = _session.get("_cooldown_cache")
	cache[FIREBALL] = {"remaining": 7, "tick": _session.tick_clock().estimated_tick()}
	print("DEMO sweep wrong_anchor fireball=7")
	_cast_phases.clear()
	_press_ability(FIREBALL)
	if not await _wait_until(func() -> bool: return _phase_count(FIREBALL, "resolve") > 0, CAST_TIMEOUT_MSEC):
		return _fail("re-anchor cast did not resolve")
	if _session.cooldown_remaining(FIREBALL) < 70:
		return _fail("resolve did not replace deliberately wrong cooldown anchor")
	if not await _sweep_observation("re-anchor", 5):
		return 1
	if not await _wait_for_ready(FIREBALL):
		return 1
	if not await _sweep_observation("clear", 6):
		return 1
	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _wait_for_sweep(ability_id: String, visible: bool) -> bool:
	return await _wait_until(
		func() -> bool: return (_session.cooldown_remaining(ability_id) > 0) == visible,
		CASTBAR_TIMEOUT_MSEC,
	)


func _sweep_observation(state: String, shot: int) -> bool:
	await _tree.process_frame
	var hotbar: HotbarScript = _session.get("_hotbar") as HotbarScript
	if hotbar != null:
		hotbar.refresh_cooldowns()
	var slot: Variant = hotbar.slot_2 if hotbar != null else null
	var remaining := _session.cooldown_remaining(FIREBALL)
	var total := int(AbilityDefs.get_ability(hotbar.catalog(), FIREBALL).get("cooldown_ticks", 0)) if hotbar != null else 0
	var overlay: bool = slot != null and slot.cooling != null and slot.cooling.visible
	var fraction := 0.0
	if overlay:
		fraction = 1.0 - slot.cooling.anchor_top
	print("DEMO sweep %s ability=fireball remaining=%d total=%d overlay=%d fraction=%.3f" % [state, remaining, total, int(overlay), fraction])
	if state == "appearing" and (remaining <= 0 or not overlay):
		_fail("cooldown overlay did not appear")
		return false
	if state == "draining" and (remaining <= 0 or (_sweep_previous_remaining > 0 and remaining >= _sweep_previous_remaining)):
		_fail("cooldown did not drain between samples")
		return false
	if state == "idle":
		var heal_slot: Variant = hotbar.slot_1 if hotbar != null else null
		if heal_slot == null or heal_slot.cooling == null or heal_slot.cooling.visible:
			_fail("ready heal slot showed an overlay")
			return false
	if state == "clear" and (remaining != 0 or overlay):
		_fail("cooldown overlay remained after reaching zero")
		return false
	if remaining > 0 and (not overlay or absf(fraction - float(remaining) / total) > 0.1):
		_fail("overlay fraction is not within 0.1 of authoritative remaining/total")
		return false
	if state == "draining":
		_sweep_previous_remaining = remaining
	return await _capture(shot)


func _cooldown_proof_requested() -> bool:
	return OS.get_cmdline_user_args().has("--cast-bar-cooldown-proof")


func _refusal_demo_requested() -> bool:
	return OS.get_cmdline_user_args().has("--cast-bar-refusal-demo")


func _oom_demo_requested() -> bool:
	return OS.get_cmdline_user_args().has("--cast-bar-oom-demo")


func _run_oom_demo(hostile_id: int) -> int:
	var net: Node = _session.get("net")
	var error_hud: ErrorHudScript = _session.get("_error_hud") as ErrorHudScript
	var begins_before := _phase_count(FIREBALL, "begin")
	var refusals_before := _refusals.size()
	var out_of_range_id := _out_of_range_hostile_id()
	if out_of_range_id == 0:
		return _fail("no hostile NPC is reliably outside fireball range")
	print("DEMO select %d hostile out_of_range" % out_of_range_id)
	if net == null or net.send_cast(FIREBALL, out_of_range_id) != OK:
		return _fail("could not send the out-of-range cast intent")
	if not await _wait_until(func() -> bool: return _refusals.size() > refusals_before, CASTBAR_TIMEOUT_MSEC):
		return _fail("out-of-range cast refusal did not arrive")
	if String(_refusals.back().get("reason", "")) != "out_of_range":
		return _fail("expected out_of_range decoded reason, got %s" % [_refusals.back()])
	if error_hud == null or error_hud.text != "Out of range":
		return _fail("out-of-range HUD did not display its reason-keyed copy")
	print("DEMO errortext %s" % error_hud.text)
	var range_tint: Color = error_hud.message_label.get_theme_color("font_color")
	print("DEMO errortint out_of_range %s" % range_tint.to_html())
	if not await _capture(1):
		return 1
	refusals_before = _refusals.size()
	var mana_before := _session.mana_for(_session.own_id()).x
	if net.send_cast(FIREBALL, hostile_id) != OK:
		return _fail("could not send the insufficient-mana cast intent")
	if not await _wait_until(func() -> bool: return _refusals.size() > refusals_before, CASTBAR_TIMEOUT_MSEC):
		return _fail("insufficient-mana cast refusal did not arrive")
	if String(_refusals.back().get("reason", "")) != "insufficient_mana":
		return _fail("expected insufficient_mana decoded reason, got %s" % [_refusals.back()])
	if error_hud == null or error_hud.text != "Not enough mana":
		return _fail("insufficient-mana HUD did not display its reason-keyed copy")
	var mana_tint: Color = error_hud.message_label.get_theme_color("font_color")
	if mana_tint == range_tint:
		return _fail("out-of-mana and out-of-range tints are not distinct")
	print("DEMO errortint insufficient_mana %s" % mana_tint.to_html())
	if mana_before >= 25 or _session.mana_for(_session.own_id()).x != mana_before:
		return _fail("insufficient-mana refusal changed mana (before=%d after=%d)" % [mana_before, _session.mana_for(_session.own_id()).x])
	if _phase_count(FIREBALL, "begin") != begins_before:
		return _fail("a refused OOR/OOM press emitted cast_begin")
	print("DEMO refusal mana_before=%d mana_after=%d begins=%d" % [mana_before, _session.mana_for(_session.own_id()).x, _phase_count(FIREBALL, "begin")])
	print("DEMO errortext %s" % error_hud.text)
	if not await _capture(2):
		return 1
	await _wait_msec(int(error_hud.linger.wait_time * 1000.0) + 100)
	if error_hud.visible or not error_hud.text.is_empty():
		return _fail("insufficient-mana HUD did not clear after authored linger")
	print("DEMO errorcleared")
	print("DEMO done")
	return 0


func _out_of_range_hostile_id() -> int:
	var local: Node3D = _session.avatar_for(_session.own_id())
	if local == null:
		return 0
	var candidates: Dictionary = _session.get("_npcs")
	var furthest_id := 0
	var furthest_distance := 8.0
	for value: Variant in candidates.keys():
		var npc: NpcDummyScript = candidates[value] as NpcDummyScript
		if npc == null or npc.faction != NpcDummyScript.FactionHostile:
			continue
		var distance := local.global_position.distance_to(npc.global_position)
		if distance > furthest_distance:
			furthest_distance = distance
			furthest_id = int(value)
	return furthest_id


func _run_refusal_demo(hostile_id: int) -> int:
	if not await _cast_resolve(hostile_id):
		return 1
	if not await _refuse_inside_cooldown(FIREBALL):
		return 1
	if not await _capture(1):
		return 1
	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _run_cooldown_proof(hostile_id: int) -> int:
	print("DEMO cooldown first_ready %s" % FIREBALL)
	if not await _cast_resolve(hostile_id):
		return 1
	if not _has_cooldown_update(FIREBALL, 75):
		return _fail("fireball resolve did not carry cooldown=75")
	print("DEMO cooldown_resolve %s cooldown=75" % FIREBALL)
	if not await _refuse_inside_cooldown(FIREBALL):
		return 1
	if not await _capture(1):
		return 1
	if not await _wait_for_connection():
		return 1
	if not await _wait_for_ready(FIREBALL):
		return 1
	if not await _cast_resolve(hostile_id):
		return 1
	print("DEMO cooldown_after_ready %s cooldown=75" % FIREBALL)

	if not await _heal_resolve():
		return 1
	if not _has_cooldown_update("heal", 38):
		return _fail("heal resolve did not carry cooldown=38")
	print("DEMO cooldown_resolve heal cooldown=38")
	if not await _refuse_inside_cooldown("heal"):
		return 1

	if not await _reconnect_with_cooldowns():
		return 1
	if not await _capture(2):
		return 1
	if not await _wait_for_connection():
		return 1
	if not _session.select_player(_hostile_dummy_id()):
		return _fail("could not reselect hostile dummy after reconnect")
	if not await _wait_for_ready(FIREBALL):
		return 1
	if not await _cancel_then_resolve(hostile_id):
		return 1
	if not await _capture(3):
		return 1

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _heal_resolve() -> bool:
	var resolve_before := _phase_count("heal", "resolve")
	var mana_before := _session.mana_for(_session.own_id()).x
	_press_ability("heal")
	print("DEMO cooldown_cast heal")
	if not await _wait_until(
		func() -> bool: return _phase_count("heal", "resolve") > resolve_before,
		CAST_TIMEOUT_MSEC,
	):
		_fail("heal never resolved")
		return false
	if not await _wait_until(
		func() -> bool: return _has_cooldown_update("heal", 38),
		CASTBAR_TIMEOUT_MSEC,
	):
		_fail("heal resolve did not reach the client cooldown cache")
		return false
	var mana_after := _session.mana_for(_session.own_id()).x
	if mana_before >= 0 and mana_after >= mana_before:
		_fail("heal resolve did not spend mana (%d -> %d)" % [mana_before, mana_after])
		return false
	return true


func _refuse_inside_cooldown(ability_id: String) -> bool:
	var refusals_before := _refusals.size()
	var begins_before := _phase_count(ability_id, "begin")
	var mana_before := _session.mana_for(_session.own_id()).x
	_press_ability(ability_id)
	print("DEMO cooldown_press %s mana=%d begins=%d" % [ability_id, mana_before, begins_before])
	if not await _wait_until(
		func() -> bool: return _refusals.size() > refusals_before,
		CASTBAR_TIMEOUT_MSEC,
	):
		_fail("%s cooldown press produced no refusal frame" % ability_id)
		return false
	var refusal: Dictionary = _refusals.back()
	if String(refusal.get("re", "")) != "cast" or String(refusal.get("reason", "")) != "cooldown":
		_fail("%s refusal was not decoded with cooldown reason: %s" % [ability_id, refusal])
		return false
	var error_hud: ErrorHudScript = _session.get("_error_hud") as ErrorHudScript
	if error_hud == null or not error_hud.visible or error_hud.text != "Not ready yet":
		_fail("cooldown error HUD did not show its reason-keyed text")
		return false
	print("DEMO errortext %s" % error_hud.text)
	await _wait_msec(int(error_hud.linger.wait_time * 1000.0) + 100)
	if error_hud.visible or not error_hud.text.is_empty():
		_fail("error HUD did not clear after authored linger")
		return false
	print("DEMO errorcleared")
	await _wait_msec(100)
	if _phase_count(ability_id, "begin") != begins_before:
		_fail("%s cooldown refusal began a cast" % ability_id)
		return false
	print("DEMO cooldown_refuse %s mana_before=%d begins=%d" % [ability_id, mana_before, begins_before])
	return true


func _reconnect_with_cooldowns() -> bool:
	var net: Node = _session.get("net")
	if net == null or not net.has_method("abandon"):
		_fail("net client cannot abandon for cooldown welcome resync")
		return false
	var welcomes_before := _welcome_cooldowns.size()
	net.abandon()
	if not await _wait_until(
		func() -> bool: return _welcome_cooldowns.size() > welcomes_before,
		JOIN_TIMEOUT_MSEC,
	):
		_fail("reconnect did not deliver a cooldown welcome")
		return false
	var snapshot: Array = _welcome_cooldowns.back()
	var fireball_remaining := _snapshot_remaining(snapshot, FIREBALL)
	var heal_remaining := _snapshot_remaining(snapshot, "heal")
	if fireball_remaining <= 0 or fireball_remaining >= 75 or heal_remaining <= 0 or heal_remaining >= 38:
		_fail("welcome cooldowns were not mid-cooldown values: %s" % [snapshot])
		return false
	if _session.cooldown_remaining(FIREBALL) <= 0 or _session.cooldown_remaining("heal") <= 0:
		_fail("welcome cooldowns did not re-anchor the client cache")
		return false
	print("DEMO cooldown_welcome fireball=%d heal=%d" % [fireball_remaining, heal_remaining])
	return true


func _cancel_then_resolve(hostile_id: int) -> bool:
	_cast_seen.clear()
	var begin_before := _phase_count(FIREBALL, "begin")
	var cancel_before := _phase_count(FIREBALL, "cancel")
	_press_ability(FIREBALL)
	print("DEMO cooldown_cancel_start %s" % FIREBALL)
	if not await _wait_until(
		func() -> bool: return _phase_count(FIREBALL, "begin") > begin_before and _cast_progress() >= 1,
		CASTBAR_TIMEOUT_MSEC,
	):
		_fail("cancel proof fireball did not begin")
		return false
	_session.request_move(STEER_DX, STEER_DZ)
	await _tree.create_timer(0.05).timeout
	_session.request_move(0.0, 0.0)
	if not await _wait_until(
		func() -> bool: return _phase_count(FIREBALL, "cancel") > cancel_before,
		CAST_TIMEOUT_MSEC,
	):
		_fail("cancel proof fireball did not cancel on movement")
		return false
	if _session.cooldown_remaining(FIREBALL) != 0:
		_fail("cancelled fireball started a cooldown")
		return false
	print("DEMO cooldown_cancel %s remaining=0" % FIREBALL)
	print("DEMO castcancel %s %d" % [FIREBALL, hostile_id])
	if not await _cast_resolve(hostile_id):
		return false
	if not _has_cooldown_update(FIREBALL, 75):
		_fail("after-ready fireball resolve did not carry cooldown=75")
		return false
	print("DEMO cooldown_after_ready %s cooldown=75" % FIREBALL)
	return true


func _wait_for_connection() -> bool:
	var net: Node = _session.get("net")
	if net == null or not net.has_method("is_open"):
		_fail("net client cannot report whether it is connected")
		return false
	var ticks_before := _ticks_received
	if not await _wait_until(
		func() -> bool: return net.is_open() and _ticks_received > ticks_before,
		JOIN_TIMEOUT_MSEC,
	):
		_fail("client did not receive a fresh server tick after screenshot")
		return false
	return true


func _wait_for_ready(ability_id: String) -> bool:
	if not await _wait_until(
		func() -> bool: return _session.cooldown_remaining(ability_id) == 0,
		COOLDOWN_WAIT_MSEC,
	):
		_fail("%s never became ready after %dms" % [ability_id, COOLDOWN_WAIT_MSEC])
		return false
	var tick_msec := int(_session.get("_tick_ms"))
	await _wait_msec(COOLDOWN_READY_GUARD_TICKS * tick_msec)
	print("DEMO cooldown_ready %s" % ability_id)
	return true


func _phase_count(ability_id: String, phase: String) -> int:
	var count := 0
	for entry: Variant in _cast_phases:
		var row: Dictionary = entry
		if String(row.get("ability", "")) == ability_id and String(row.get("phase", "")) == phase:
			count += 1
	return count


func _has_cooldown_update(ability_id: String, cooldown: int) -> bool:
	for entry: Variant in _cooldown_updates:
		var row: Dictionary = entry
		if String(row.get("ability", "")) == ability_id and int(row.get("cooldown", 0)) == cooldown:
			return true
	return false


func _snapshot_remaining(snapshot: Array, ability_id: String) -> int:
	for entry: Variant in snapshot:
		var row: Dictionary = entry
		if String(row.get("ability", "")) == ability_id:
			return int(row.get("remaining", 0))
	return 0


func _on_cast_effect(target_id: int, ability_id: String) -> void:
	_effects.append({"target": target_id, "ability": ability_id})
	print("DEMO castfx %d %s" % [target_id, ability_id])


func _on_cast_phase(id: int, ability_id: String, target_id: int, phase: String) -> void:
	if id != _session.own_id():
		return
	_cast_phases.append({"ability": ability_id, "target": target_id, "phase": phase})
	print("DEMO castphase %s %s" % [ability_id, phase])


func _on_server_error(reason: String, re: String, message: String) -> void:
	_refusals.append({"reason": reason, "re": re, "message": message})
	print("DEMO castrefusal reason=%s re=%s msg=%s" % [reason, re, message])


func _on_cast_cooldown(id: int, ability_id: String, cooldown: int) -> void:
	if id != _session.own_id():
		return
	_cooldown_updates.append({"ability": ability_id, "cooldown": cooldown})
	print("DEMO castcooldown %s %d" % [ability_id, cooldown])


func _on_cooldowns_received(cooldowns: Array) -> void:
	_welcome_cooldowns.append(cooldowns.duplicate(true))
	print("DEMO cooldown_welcome_frame %s" % [cooldowns])


func _on_tick_received(_tick: int) -> void:
	_ticks_received += 1


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
