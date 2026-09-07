extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const ClassDebugScript := preload("res://scripts/class_debug.gd")
const Assertions := preload("res://tests/assertions.gd")

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _class_debug: ClassDebugScript = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== class debug: active class readable string ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "ClassDebugClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_class_debug = _root.get_node("UI/ClassDebug") as ClassDebugScript

	await get_tree().process_frame
	await get_tree().process_frame

	_test_class_debug_authored_in_scene()
	await _test_starts_none()
	await _test_active_miner_with_level()
	await _test_skills_restatement_updates_level()
	await _test_inactive_clears_debug()
	await _test_welcome_clears_debug()
	await _test_other_player_skills_ignored()

	print(
		"CLASS DEBUG RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_class_debug_authored_in_scene() -> void:
	_check(_class_debug != null, "main.tscn authors a class debug control")
	_check(
		_class_debug.get_node_or_null("DebugLabel") != null,
		"debug label is scene-authored",
	)
	var source := FileAccess.get_file_as_string("res://scripts/session.gd")
	_check(
		not source.contains("ClassDebugScript.new("),
		"session never builds class debug at runtime",
	)


func _test_starts_none() -> void:
	_check(
		_class_debug.text == "None",
		'class debug starts as "None", got "%s"' % _class_debug.text,
	)


func _test_active_miner_with_level() -> void:
	await _feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100}]}}'
	)
	await _feed('{"class":{"player":1,"class":"miner"}}')
	await _feed(
		'{"skills":{"player":1,"skills":[{"id":"mining","xp":3300,"level":34},'
		+ '{"id":"combat","xp":0,"level":1}]}}'
	)
	_check(
		_session.active_class_debug_text() == "Miner Lv 34 (mining)",
		'active miner reads "Miner Lv 34 (mining)", got "%s"'
		% _session.active_class_debug_text(),
	)
	print("DEMO class debug=%s" % _session.active_class_debug_text())


func _test_skills_restatement_updates_level() -> void:
	await _feed(
		'{"skills":{"player":1,"skills":[{"id":"mining","xp":3600,"level":37},'
		+ '{"id":"combat","xp":0,"level":1}]}}'
	)
	_check(
		_session.active_class_debug_text() == "Miner Lv 37 (mining)",
		'skills restatement updates debug to "Miner Lv 37 (mining)", got "%s"'
		% _session.active_class_debug_text(),
	)
	print("DEMO class debug=%s" % _session.active_class_debug_text())


func _test_inactive_clears_debug() -> void:
	await _feed('{"class":{"player":1,"class":""}}')
	_check(
		_session.active_class_debug_text() == "None",
		'inactive class reads "None", got "%s"' % _session.active_class_debug_text(),
	)


func _test_welcome_clears_debug() -> void:
	await _feed('{"class":{"player":1,"class":"knight"}}')
	await _feed(
		'{"skills":{"player":1,"skills":[{"id":"combat","xp":500,"level":6}]}}'
	)
	_check(
		_session.active_class_debug_text() == "Knight Lv 6 (combat)",
		"knight is shown before welcome clears",
	)
	await _feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":2,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100}]}}'
	)
	_check(
		_session.active_class_debug_text() == "None",
		'welcome clears debug to "None", got "%s"' % _session.active_class_debug_text(),
	)


func _test_other_player_skills_ignored() -> void:
	await _feed('{"class":{"player":1,"class":"archer"}}')
	await _feed(
		'{"skills":{"player":1,"skills":[{"id":"ranged","xp":0,"level":5}]}}'
	)
	await _feed(
		'{"skills":{"player":2,"skills":[{"id":"magic","xp":0,"level":99}]}}'
	)
	_check(
		_session.active_class_debug_text() == "Archer Lv 5 (ranged)",
		"other player's skills do not repaint self debug, got \"%s\""
		% _session.active_class_debug_text(),
	)


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
