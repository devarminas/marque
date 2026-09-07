extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const ErrorHudScript := preload("res://scripts/error_hud.gd")
const Assertions := preload("res://tests/assertions.gd")

const CLASS_GATE_DETAIL := "gather requires an active class whose skill matches this node"
const NO_TOOL_TEXT := "usable tool not equipped"
const DEPLETED_DETAIL := "that node is depleted"
const NON_GATHER_DETAIL := "no such item"

const LINGER_SECONDS := 4.0

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _error_hud: ErrorHudScript = null
var _linger: Timer = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== error hud: a refusal reaches the player ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "ErrorHudClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_error_hud = _root.get_node("UI/ErrorHud") as ErrorHudScript
	_linger = _root.get_node_or_null("UI/ErrorHud/Linger") as Timer

	await get_tree().process_frame
	await get_tree().process_frame

	_test_the_hud_is_authored_in_the_scene()
	_test_the_class_gate_detail_maps_to_the_player_text()
	_test_any_other_refusal_passes_through()
	await _test_a_class_gate_error_frame_paints_the_hud()
	await _test_an_unmapped_gather_error_frame_shows_the_server_text()
	_test_clearing_empties_and_hides()

	print(
		"ERROR HUD RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_hud_is_authored_in_the_scene() -> void:
	_check(_error_hud != null, "main.tscn authors an error hud control")
	_check(
		_error_hud.get_node_or_null("MessageLabel") != null,
		"the message label is scene-authored",
	)
	_check(_linger != null, "the linger timer is scene-authored")
	_check(
		_linger != null and is_equal_approx(_linger.wait_time, LINGER_SECONDS),
		"the linger timer waits %.1fs, got %.1f"
		% [LINGER_SECONDS, _linger.wait_time if _linger != null else 0.0],
	)
	_check(_linger != null and _linger.one_shot, "the linger timer is one-shot")
	_check(
		_linger != null and not _linger.autostart,
		"the linger timer does not autostart",
	)
	_check(
		_linger != null and _linger.timeout.is_connected(Callable(_error_hud, "clear")),
		"the scene connects the linger timeout to clear",
	)
	_check(not _error_hud.visible, "the hud starts hidden")
	_check(_error_hud.text.is_empty(), 'the hud starts empty, got "%s"' % _error_hud.text)
	var source := FileAccess.get_file_as_string("res://scripts/session.gd")
	_check(
		not source.contains("ErrorHudScript.new("),
		"session never builds the error hud at runtime",
	)


func _test_the_class_gate_detail_maps_to_the_player_text() -> void:
	_check(
		SessionScript.player_refusal_text("gather", CLASS_GATE_DETAIL) == NO_TOOL_TEXT,
		'the class gate detail reads "%s", got "%s"'
		% [NO_TOOL_TEXT, SessionScript.player_refusal_text("gather", CLASS_GATE_DETAIL)],
	)


func _test_any_other_refusal_passes_through() -> void:
	_check(
		SessionScript.player_refusal_text("gather", DEPLETED_DETAIL) == DEPLETED_DETAIL,
		'another gather refusal keeps the server text, got "%s"'
		% SessionScript.player_refusal_text("gather", DEPLETED_DETAIL),
	)
	_check(
		SessionScript.player_refusal_text("move_to", NON_GATHER_DETAIL) == NON_GATHER_DETAIL,
		'a non-gather refusal keeps the server text, got "%s"'
		% SessionScript.player_refusal_text("move_to", NON_GATHER_DETAIL),
	)
	_check(
		SessionScript.player_refusal_text("pickup", CLASS_GATE_DETAIL) == CLASS_GATE_DETAIL,
		"the class gate detail is only special under gather, got \"%s\""
		% SessionScript.player_refusal_text("pickup", CLASS_GATE_DETAIL),
	)


func _test_a_class_gate_error_frame_paints_the_hud() -> void:
	await _feed('{"error":{"re":"gather","msg":"%s"}}' % CLASS_GATE_DETAIL)
	_check(
		_error_hud.text == NO_TOOL_TEXT,
		'a class-gate gather error draws "%s", got "%s"' % [NO_TOOL_TEXT, _error_hud.text],
	)
	_check(_error_hud.visible, "and shows the hud")
	_check(_linger != null and not _linger.is_stopped(), "and starts the linger timer")


func _test_an_unmapped_gather_error_frame_shows_the_server_text() -> void:
	await _feed('{"error":{"re":"gather","msg":"%s"}}' % DEPLETED_DETAIL)
	_check(
		_error_hud.text == DEPLETED_DETAIL,
		'an unmapped gather error draws "%s", got "%s"' % [DEPLETED_DETAIL, _error_hud.text],
	)


func _test_clearing_empties_and_hides() -> void:
	_error_hud.clear()
	_check(_error_hud.text.is_empty(), 'clear empties the label, got "%s"' % _error_hud.text)
	_check(not _error_hud.visible, "clear hides the hud")
	_check(_linger != null and _linger.is_stopped(), "clear stops the linger timer")


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
