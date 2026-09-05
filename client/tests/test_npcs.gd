extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const Assertions := preload("res://tests/assertions.gd")

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _casts: Array = []


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== npcs: welcome, select, cast faction targets ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "NpcClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_session.cast_requested.connect(
		func(ability_id: String, target_id: int) -> void:
			_casts.append({"ability": ability_id, "player": target_id})
	)

	await get_tree().process_frame
	await get_tree().process_frame

	_feed_welcome_with_npcs()
	await get_tree().process_frame
	await get_tree().process_frame

	_test_bodies_and_select()
	_test_cast_targets()

	_finished = true


func _feed_welcome_with_npcs() -> void:
	_net.ingest_text_frame(
		'{"welcome":{"you":3,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":3,"x":0.0,"z":0.0,"hp":100,"max_hp":100,"mana":100,"max_mana":100}],'
		+ '"items":[],"nodes":[],'
		+ '"npcs":['
		+ '{"id":1000001,"kind":"dummy","faction":"friendly","x":-3.0,"z":0.0,"hp":100,"max_hp":100},'
		+ '{"id":1000002,"kind":"dummy","faction":"hostile","x":3.0,"z":0.0,"hp":100,"max_hp":100}'
		+ "]}}"
	)


func _test_bodies_and_select() -> void:
	var npcs: Dictionary = _session.get("_npcs")
	_check(npcs.size() == 2, "session registry holds two npcs")
	var friendly: NpcDummyScript = npcs.get(1000001)
	var hostile: NpcDummyScript = npcs.get(1000002)
	_check(friendly != null and hostile != null, "both dummy bodies exist")
	if friendly == null or hostile == null:
		return
	_check(friendly.faction == "friendly", "id 1000001 is friendly")
	_check(hostile.faction == "hostile", "id 1000002 is hostile")
	_check(_session.select_player(1000001), "select friendly dummy")
	_check(_session.selected_player_id() == 1000001, "selection is friendly")
	_check(friendly.is_selected(), "friendly chrome on")
	_check(not hostile.is_selected(), "hostile chrome off")
	_check(_session.select_player(1000002), "select hostile dummy")
	_check(_session.selected_player_id() == 1000002, "selection is hostile")
	_check(hostile.is_selected(), "hostile chrome on")
	_check(not friendly.is_selected(), "friendly chrome off")


func _test_cast_targets() -> void:
	_casts.clear()
	_session.select_player(1000001)
	_session.request_cast("heal")
	_check(_casts.size() == 1, "heal emits one cast")
	if _casts.size() == 1:
		_check(_casts[0]["player"] == 1000001, "heal targets friendly selection")

	_casts.clear()
	_session.select_player(1000002)
	_session.request_cast("heal")
	_check(_casts.size() == 1, "heal with hostile selection still emits")
	if _casts.size() == 1:
		_check(_casts[0]["player"] == 3, "heal falls back to self on hostile selection")

	_casts.clear()
	_session.select_player(1000002)
	_session.request_cast("fireball")
	_check(_casts.size() == 1, "fireball emits one cast")
	if _casts.size() == 1:
		_check(_casts[0]["player"] == 1000002, "fireball targets hostile selection")


func _check(cond: bool, msg: String) -> void:
	_assertions.check(cond, msg)
