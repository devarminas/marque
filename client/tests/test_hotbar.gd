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
	_check(slot1 != null and slot2 != null, "both slots are authored")
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


func _check(cond: bool, msg: String) -> void:
	_assertions.check(cond, msg)
