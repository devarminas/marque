extends Node3D

## Resource node registry and bodies, driven by scripted frames. **M4b.**

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")
const Assertions := preload("res://tests/assertions.gd")

const EXACT_EPSILON := 0.002
const CHANNEL_EPSILON := 0.25

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _container: Node3D = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	_root = MainScene.instantiate() as Node3D
	_root.name = "NodesClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_container = _root.get_node("ResourceNodes") as Node3D

	await get_tree().process_frame
	await get_tree().process_frame

	print("== nodes: the third registry, no server ==")
	_test_the_container_is_authored()
	_test_welcome_builds_node_bodies()
	_test_node_ids_are_a_separate_space()
	_test_node_spawn_and_state()
	_test_node_despawn()
	_test_depleted_is_visually_distinct()
	_test_an_unknown_kind_is_magenta()
	_test_a_second_welcome_frees_nodes()

	print(
		"NODES RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_container_is_authored() -> void:
	_check(_container != null, "main.tscn authors a ResourceNodes container")
	_check(
		_container != null and _container.get_child_count() == 0,
		"which starts empty, because how many nodes exist is runtime information",
	)
	_check(
		_session != null and _session.known_node_ids().is_empty(),
		"and the session believes in no nodes before welcome",
	)


func _test_welcome_builds_node_bodies() -> void:
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":142,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"nodes":[{"id":1,"kind":"tree","x":5.0,"z":0.0,"state":"full"},'
		+ '{"id":2,"kind":"tree","x":-3.0,"z":4.0,"state":"depleted"}]}}'
	)
	_check(
		_session.known_node_ids() == [1, 2],
		"welcome.nodes registers both ids, got %s" % [_session.known_node_ids()],
	)
	var full: ResourceNodeScript = _session.node_for(1)
	_check(full != null, "node 1 has a body")
	if full != null:
		_check(full.get_parent() == _container, "hanging under ResourceNodes")
		_check(
			full.position.distance_to(Vector3(5.0, full.ground_y, 0.0)) < EXACT_EPSILON,
			"at the welcome position",
		)
		_check(full.state == "full", 'state is "full"')
		_check(full.foliage != null and full.foliage.visible, "full tree shows foliage")
	var depleted: ResourceNodeScript = _session.node_for(2)
	_check(depleted != null and depleted.is_depleted(), "node 2 starts depleted")
	if depleted != null:
		_check(
			depleted.foliage != null and not depleted.foliage.visible,
			"depleted tree hides foliage",
		)


func _test_node_ids_are_a_separate_space() -> void:
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":10,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"items":[{"id":1,"kind":"acorn","x":1.0,"z":1.0}],'
		+ '"nodes":[{"id":1,"kind":"tree","x":2.0,"z":2.0,"state":"full"}]}}'
	)
	_check(_session.item_for(1) != null, "item 1 exists")
	_check(_session.node_for(1) != null, "node 1 exists")
	_check(
		_session.item_for(1) != (_session.node_for(1) as Object),
		"and they are different bodies sharing a number",
	)


func _test_node_spawn_and_state() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":7,"kind":"tree","x":3.0,"z":-2.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(7)
	_check(body != null, "node_spawn builds a body")
	if body != null:
		_check(body.state == "full", "full on spawn")
	_feed('{"node_state":{"id":7,"kind":"tree","x":3.0,"z":-2.0,"state":"depleted"}}')
	_check(
		_session.node_for(7) != null and _session.node_for(7).is_depleted(),
		"node_state depleted switches the visual state",
	)
	_feed('{"node_state":{"id":7,"kind":"tree","x":3.0,"z":-2.0,"state":"full"}}')
	_check(
		_session.node_for(7) != null and not _session.node_for(7).is_depleted(),
		"and full restores it",
	)


func _test_node_despawn() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":9,"kind":"tree","x":0.0,"z":0.0,"state":"full"}}')
	_check(_session.node_for(9) != null, "node 9 is present")
	_feed('{"node_despawn":{"id":9}}')
	_check(_session.node_for(9) == null, "node_despawn removes it")
	_check(
		_container.get_child_count() == 0,
		"leaving ResourceNodes empty, got %d" % _container.get_child_count(),
	)


func _test_depleted_is_visually_distinct() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":4,"kind":"tree","x":0.0,"z":0.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(4)
	_check(body != null, "full tree exists")
	if body == null:
		return
	var full_scale := body.scale
	var full_color := body.drawn_color()
	var foliage_was_visible := body.foliage != null and body.foliage.visible
	_feed('{"node_state":{"id":4,"kind":"tree","x":0.0,"z":0.0,"state":"depleted"}}')
	_check(body.is_depleted(), "now depleted")
	var foliage_hidden := body.foliage != null and not body.foliage.visible
	_check(
		body.scale != full_scale or body.drawn_color() != full_color
		or (foliage_was_visible and foliage_hidden),
		"depleted changes scale, color, or foliage visibility",
	)


func _test_an_unknown_kind_is_magenta() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":11,"kind":"crystal","x":0.0,"z":0.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(11)
	_check(body != null, "unknown kind still builds a body")
	if body == null:
		return
	_check(not body.is_kind_known(), "kind is unknown")
	var color := body.drawn_color()
	_check(
		absf(color.r - 0.95) < CHANNEL_EPSILON
		and absf(color.g - 0.08) < CHANNEL_EPSILON
		and absf(color.b - 0.85) < CHANNEL_EPSILON,
		"and draws magenta, got %s" % color,
	)


func _test_a_second_welcome_frees_nodes() -> void:
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"nodes":[{"id":1,"kind":"tree","x":1.0,"z":1.0,"state":"full"}]}}'
	)
	_check(_session.node_for(1) != null, "first welcome has a node")
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":2,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"nodes":[{"id":8,"kind":"tree","x":2.0,"z":2.0,"state":"full"}]}}'
	)
	_check(_session.node_for(1) == null, "second welcome drops the old node")
	_check(_session.node_for(8) != null, "and builds the new one")


func _welcome_empty() -> String:
	return (
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}]}}'
	)


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
