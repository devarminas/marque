extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const HpHudScript := preload("res://scripts/hp_hud.gd")
const DeathOverlayScript := preload("res://scripts/death_overlay.gd")
const Assertions := preload("res://tests/assertions.gd")

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _hp_hud: HpHudScript = null
var _death: DeathOverlayScript = null
var _respawn_intents := 0


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== hp: self display, death overlay, respawn ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "HpClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_hp_hud = _root.get_node("UI/HpHud") as HpHudScript
	_death = _root.get_node("UI/DeathOverlay") as DeathOverlayScript

	_session.respawn_requested.connect(func() -> void: _respawn_intents += 1)

	await get_tree().process_frame
	await get_tree().process_frame

	_test_overlay_authored_stop()
	await _test_welcome_draws_self_hp()
	await _test_live_hp_updates_display()
	await _test_death_shows_overlay()
	await _test_respawn_button_sends_intent()
	await _test_full_hp_hides_overlay()
	await _test_other_player_hp_label()

	print(
		"HP RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_overlay_authored_stop() -> void:
	_check(_death != null, "main.tscn authors a death overlay")
	_check(not _death.visible, "death overlay starts hidden")
	_check(
		_death.mouse_filter == Control.MOUSE_FILTER_STOP,
		"and STOP is authored in the scene, got filter %d" % _death.mouse_filter,
	)
	var source := FileAccess.get_file_as_string("res://scripts/death_overlay.gd")
	var assignment := RegEx.new()
	assignment.compile("mouse_filter\\s*=(?!=)")
	_check(
		assignment.search(source) == null,
		"death_overlay.gd never assigns mouse_filter at runtime",
	)


func _test_welcome_draws_self_hp() -> void:
	await _feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100},'
		+ '{"id":2,"x":5,"z":5,"hp":70,"max_hp":100}]}}'
	)
	_check(_hp_hud.visible, "welcome with hp shows the self chrome")
	_check(
		_hp_hud.text == "HP 100 / 100",
		'self chrome reads "HP 100 / 100", got "%s"' % _hp_hud.text,
	)
	_check(not _death.visible, "living welcome keeps the death overlay hidden")
	_check(
		_session.hit_points_for(1) == Vector2i(100, 100),
		"session caches self hp",
	)
	_check(
		_session.hit_points_for(2) == Vector2i(70, 100),
		"session caches other hp from welcome",
	)


func _test_live_hp_updates_display() -> void:
	await _feed('{"hp":{"id":1,"hp":70,"max_hp":100}}')
	_check(
		_hp_hud.text == "HP 70 / 100",
		'live hp restatement updates self chrome to 70, got "%s"' % _hp_hud.text,
	)
	_check(not _death.visible, "hp 70 keeps the overlay hidden")


func _test_death_shows_overlay() -> void:
	await _feed('{"hp":{"id":1,"hp":0,"max_hp":100}}')
	_check(_death.visible, "local hp 0 shows the death overlay")
	_check(
		_hp_hud.text == "HP 0 / 100",
		'self chrome shows zero, got "%s"' % _hp_hud.text,
	)


func _test_respawn_button_sends_intent() -> void:
	_respawn_intents = 0
	var button: Button = _death.get_node("Center/Column/RespawnButton")
	_check(button != null, "death overlay authors a Respawn button")
	if button == null:
		return
	button.pressed.emit()
	await get_tree().process_frame
	_check(_respawn_intents == 1, "Respawn emits respawn_requested once, got %d" % _respawn_intents)
	var frame := NetClientScript.respawn_frame()
	_check(frame.has("respawn"), "and the wire shape is respawn")


func _test_full_hp_hides_overlay() -> void:
	await _feed('{"hp":{"id":1,"hp":100,"max_hp":100}}')
	_check(not _death.visible, "full hp after respawn hides the overlay")
	_check(
		_hp_hud.text == "HP 100 / 100",
		'self chrome returns to 100, got "%s"' % _hp_hud.text,
	)


func _test_other_player_hp_label() -> void:
	await _feed('{"hp":{"id":2,"hp":40,"max_hp":100}}')
	var other := _session.avatar_for(2)
	_check(other != null, "other player has a body")
	if other == null:
		return
	var label: Label3D = other.get_node("HpLabel")
	_check(label != null and label.visible, "other HP label is visible")
	_check(
		label != null and label.text == "40/100",
		'other HP label reads "40/100", got "%s"' % (label.text if label else ""),
	)


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
