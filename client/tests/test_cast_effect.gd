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
var _effects: Array = []


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== cast effect: server mana confirm plays VFX on target ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "CastFxClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_session.cast_effect_played.connect(
		func(target_id: int, ability_id: String) -> void:
			_effects.append({"target": target_id, "ability": ability_id})
	)

	await get_tree().process_frame
	await get_tree().process_frame

	_feed_welcome_with_npcs()
	await get_tree().process_frame
	await get_tree().process_frame

	_test_success_plays_on_target()
	_test_refuse_plays_nothing()
	_test_caster_mana_without_pending_plays_nothing()

	print(
		"CAST EFFECT RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
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


func _test_success_plays_on_target() -> void:
	_effects.clear()
	_session.note_cast_sent("fireball", 1000002)
	_check(_session.pending_cast_count() == 1, "pending cast recorded before mana")
	_net.ingest_text_frame('{"mana":{"id":3,"mana":80,"max_mana":100}}')
	_check(_effects.size() == 1, "mana drop plays one cast effect")
	if _effects.size() == 1:
		_check(_effects[0]["target"] == 1000002, "effect targets the fireball dummy")
		_check(_effects[0]["ability"] == "fireball", "effect names fireball")
	_check(_session.pending_cast_count() == 0, "pending cleared after success")
	var npcs: Dictionary = _session.get("_npcs")
	var hostile: NpcDummyScript = npcs.get(1000002)
	_check(hostile != null, "hostile dummy exists")
	if hostile != null:
		var flash := hostile.get_node_or_null("CastHitFx")
		_check(flash != null, "flash mesh is parented on the target dummy")
		var local_avatar: Node3D = _session.get("_local")
		if local_avatar != null:
			_check(
				local_avatar.get_node_or_null("CastHitFx") == null,
				"flash is not parented on the caster",
			)


func _test_refuse_plays_nothing() -> void:
	_effects.clear()
	_session.note_cast_sent("heal", 1000001)
	_check(_session.pending_cast_count() == 1, "pending cast before refuse")
	_net.ingest_text_frame('{"error":{"re":"cast","msg":"target out of range"}}')
	_check(_effects.size() == 0, "refused cast plays no effect")
	_check(_session.pending_cast_count() == 0, "refuse clears pending")
	_net.ingest_text_frame('{"mana":{"id":3,"mana":70,"max_mana":100}}')
	_check(_effects.size() == 0, "mana after refuse without pending plays nothing")


func _test_caster_mana_without_pending_plays_nothing() -> void:
	_effects.clear()
	_net.ingest_text_frame('{"mana":{"id":3,"mana":60,"max_mana":100}}')
	_check(_effects.size() == 0, "unsolicited mana drop plays no cast effect")


func _check(cond: bool, msg: String) -> void:
	_assertions.check(cond, msg)
