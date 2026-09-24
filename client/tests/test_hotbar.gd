extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const HotbarScript := preload("res://scripts/hotbar.gd")
const HotbarSlotScript := preload("res://scripts/hotbar_slot.gd")
const Assertions := preload("res://tests/assertions.gd")

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _hotbar: HotbarScript = null
var _casts: Array = []


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== hotbar: JSON slots, activate sends cast ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "HotbarClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_hotbar = _root.get_node("UI/Hotbar") as HotbarScript
	_session.cast_requested.connect(
		func(ability_id: String, target_id: int) -> void:
			_casts.append({"ability": ability_id, "player": target_id})
	)

	await get_tree().process_frame
	await get_tree().process_frame

	_test_chrome_from_json()
	_test_cast_frame_shape()
	await _test_click_slot_sends_heal_on_self()
	await _test_click_fireball_uses_selection()
	await _test_server_anchored_sweep_states()

	print(
		"HOTBAR RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_chrome_from_json() -> void:
	_check(_hotbar != null, "main.tscn authors a center hotbar")
	_check(_hotbar.ability_id_in_slot(1) == "heal", "slot 1 is heal from JSON")
	_check(_hotbar.ability_id_in_slot(2) == "fireball", "slot 2 is fireball from JSON")
	var slot1: HotbarSlotScript = _hotbar.slot_1
	var slot2: HotbarSlotScript = _hotbar.slot_2
	_check(slot1 != null and slot2 != null, "both filled slots are authored")
	var authored := 0
	for widget in [
		_hotbar.slot_1,
		_hotbar.slot_2,
		_hotbar.slot_3,
		_hotbar.slot_4,
		_hotbar.slot_5,
		_hotbar.slot_6,
		_hotbar.slot_7,
		_hotbar.slot_8,
	]:
		if widget != null:
			authored += 1
	_check(authored == HotbarScript.SLOT_COUNT, "hotbar authors eight slots")
	for empty_n in range(3, HotbarScript.SLOT_COUNT + 1):
		_check(
			_hotbar.ability_id_in_slot(empty_n) == "",
			"slot %d stays empty until JSON assigns it" % empty_n,
		)
	_check(
		slot1.fill != null and slot1.fill.color.g > slot1.fill.color.r,
		"heal slot paint is green-dominant",
	)
	_check(
		slot2.fill != null and slot2.fill.color.r > slot2.fill.color.g,
		"fireball slot paint is red-dominant",
	)
	var anchors_ok := (
		is_equal_approx(_hotbar.anchor_left, 0.5)
		and is_equal_approx(_hotbar.anchor_right, 0.5)
		and is_equal_approx(_hotbar.anchor_top, 1.0)
		and is_equal_approx(_hotbar.anchor_bottom, 1.0)
	)
	_check(anchors_ok, "hotbar is center-bottom anchored")
	var hotbar_source := FileAccess.get_file_as_string("res://scripts/hotbar.gd")
	_check(not hotbar_source.contains("add_child("), "hotbar slot chrome stays scene-authored")


func _test_cast_frame_shape() -> void:
	var frame: Dictionary = NetClientScript.cast_frame("fireball", 7, 3)
	_check(frame.has("cast"), "cast_frame wraps cast")
	var body: Dictionary = frame["cast"]
	_check(body.get("ability") == "fireball", "ability id only, no damage field")
	_check(body.get("player") == 7, "target player rides on cast")
	_check(not body.has("damage"), "client never sends damage numbers")
	_check(body.get("seq") == 3, "seq stamps when provided")
	var heal: Dictionary = NetClientScript.cast_frame("heal", 0, 0)
	_check(not heal["cast"].has("player"), "omitted target leaves player off the wire")


func _test_click_slot_sends_heal_on_self() -> void:
	_casts.clear()
	_session.set("_you", 11)
	_hotbar.slot_1.pressed.emit()
	await get_tree().process_frame
	_check(_casts.size() == 1, "heal click emits one cast_requested")
	if _casts.size() == 1:
		_check(_casts[0]["ability"] == "heal", "heal ability id")
		_check(_casts[0]["player"] == 11, "heal targets self id")


func _test_click_fireball_uses_selection() -> void:
	_casts.clear()
	_session.set("_you", 11)
	_session.set("_selected_player_id", 22)
	_hotbar.slot_2.pressed.emit()
	await get_tree().process_frame
	_check(_casts.size() == 1, "fireball click emits one cast_requested")
	if _casts.size() == 1:
		_check(_casts[0]["ability"] == "fireball", "fireball ability id")
		_check(_casts[0]["player"] == 22, "fireball uses tab selection")


func _test_server_anchored_sweep_states() -> void:
	_session.set("_you", 11)
	_session.set("_tick_ms", 150)
	_session.tick_clock().anchor(100, 150)
	_session._on_cooldowns_received([{"ability": "fireball", "remaining": 60}])
	await get_tree().process_frame
	var slot: HotbarSlotScript = _hotbar.slot_2
	var fireball: Dictionary = _hotbar.catalog()["by_id"]["fireball"]
	var total := int(fireball["cooldown_ticks"])
	var fraction := 1.0 - slot.cooling.anchor_top
	_check(slot.state == HotbarSlotScript.STATE_COOLING and slot.cooling.visible, "remaining server cooldown displays the cooling state")
	_check(absf(fraction - float(60) / total) < 0.01, "overlay fraction equals remaining over catalog total")
	_check(slot.cooldown_label.visible and slot.cooldown_label.text == "9", "remaining seconds render in the slot")
	_check(not _hotbar.slot_1.cooling.visible, "other ready ability slot stays idle")

	_session._on_cast_cooldown_observed(11, "fireball", 75)
	_check(_session.cooldown_remaining("fireball") >= 74, "resolve replaces a stale cooldown anchor")
	_session._on_disconnected(0, "test teardown")
	await get_tree().process_frame
	_check(_session.cooldown_remaining("fireball") == 0 and not slot.cooling.visible, "teardown clears cached sweep")
	_session.tick_clock().anchor(200, 150)
	_session._on_cooldowns_received([{"ability": "fireball", "remaining": 30}])
	await get_tree().process_frame
	_check(_session.cooldown_remaining("fireball") == 30 and slot.cooling.visible, "welcome snapshot restores a mid-cooldown sweep")
	_session._on_cooldowns_received([{"ability": "fireball", "remaining": 0}])
	await get_tree().process_frame
	_check(not slot.cooling.visible and not slot.disabled and slot.state == HotbarSlotScript.STATE_READY, "zero remaining hides overlay and leaves slot enabled")
	_check(_hotbar.slot_3.disabled and _hotbar.slot_3.state == HotbarSlotScript.STATE_EMPTY, "empty slots retain the empty state")


func _check(cond: bool, msg: String) -> void:
	_assertions.check(cond, msg)
