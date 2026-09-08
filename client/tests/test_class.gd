extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const ClassHudScript := preload("res://scripts/class_hud.gd")
const Assertions := preload("res://tests/assertions.gd")

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _class_hud: ClassHudScript = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== class: server restatement drives the hud ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "ClassClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_class_hud = _root.get_node("UI/ClassHud") as ClassHudScript

	await get_tree().process_frame
	await get_tree().process_frame

	_test_class_hud_authored_in_scene()
	await _test_welcome_clears_class()
	await _test_active_class_shows_name()
	await _test_inactive_clears_stale_name()
	await _test_equipment_without_class_frame_does_not_invent()
	await _test_partial_class_shows_hint()
	await _test_other_player_class_ignored()

	print(
		"CLASS RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_class_hud_authored_in_scene() -> void:
	_check(_class_hud != null, "main.tscn authors a class hud")
	_check(not _class_hud.visible, "class hud starts hidden")
	_check(
		_class_hud.get_node_or_null("Stack/NameLabel") != null,
		"name label is scene-authored",
	)
	_check(
		_class_hud.get_node_or_null("Stack/HintLabel") != null,
		"hint label is scene-authored",
	)
	var source := FileAccess.get_file_as_string("res://scripts/session.gd")
	_check(
		not source.contains("ClassHudScript.new("),
		"session never builds class hud at runtime",
	)


func _test_welcome_clears_class() -> void:
	await _feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100}]}}'
	)
	await _feed('{"class":{"player":1,"class":"miner"}}')
	_check(_class_hud.visible, "class frame shows the hud")
	await _feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":2,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100}]}}'
	)
	_check(not _class_hud.visible, "welcome clears the class hud")
	_check(_session.active_class_id() == "", "welcome clears cached class id")


func _test_active_class_shows_name() -> void:
	await _feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100}]}}'
	)
	await _feed('{"class":{"player":1,"class":"miner"}}')
	_check(_class_hud.visible, "active class shows the hud")
	_check(
		_class_hud.text == "Miner",
		'active miner reads "Miner" from shared tables, got "%s"' % _class_hud.text,
	)
	_check(
		_session.active_class_id() == "miner",
		"session caches miner as the active class id",
	)
	_check(_class_hud.hint_text.is_empty(), "a complete class hides the hint")
	print('DEMO class hud name=%s' % _class_hud.text)


func _test_inactive_clears_stale_name() -> void:
	await _feed('{"class":{"player":1,"class":""}}')
	_check(
		_class_hud.text == "None",
		'inactive class reads "None", got "%s"' % _class_hud.text,
	)
	_check(_session.active_class_id() == "", "inactive clears cached class id")


func _test_equipment_without_class_frame_does_not_invent() -> void:
	await _feed('{"class":{"player":1,"class":"knight"}}')
	_check(_class_hud.text == "Knight", "knight is shown before the equipment-only frame")
	await _feed(
		'{"equipment":{"worn":["helmet","left hand","chest","right hand","trousers"],'
		+ '"slots":[{"slot":"right hand","kind":"sword"}]}}'
	)
	_check(
		_class_hud.text == "Knight",
		"equipment alone does not change the class name, got \"%s\"" % _class_hud.text,
	)
	_check(
		_session.active_class_id() == "knight",
		"cached class id stays knight without a class frame",
	)


func _test_partial_class_shows_hint() -> void:
	await _feed(
		'{"class":{"player":1,"class":"","missing":{"slots":[{"slot":"helmet","kind":"plate_helm"}],'
		+ '"tools":["pickaxe"]}}}'
	)
	_check(_class_hud.text == "None", "partial class still shows None for the name")
	_check(
		_class_hud.hint_text == "helmet (plate_helm), pickaxe",
		"partial class shows missing pieces, got \"%s\"" % _class_hud.hint_text,
	)
	var hint: Label = _class_hud.get_node("Stack/HintLabel") as Label
	_check(hint != null and hint.visible, "hint label is visible for partial class")


func _test_other_player_class_ignored() -> void:
	await _feed('{"class":{"player":1,"class":"archer"}}')
	_check(_class_hud.text == "Archer", "self class is archer before the other-player frame")
	await _feed('{"class":{"player":2,"class":"mage"}}')
	_check(
		_class_hud.text == "Archer",
		"other player's class frame does not repaint self chrome, got \"%s\"" % _class_hud.text,
	)
	_check(_session.active_class_id() == "archer", "cached class id stays archer")


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
