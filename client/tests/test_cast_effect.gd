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
	print("== cast effect: a cast resolve plays VFX on its target ==")

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

	_test_resolve_after_the_real_frame_order()
	_test_self_target_plays_on_local()
	_test_begin_and_cancel_play_nothing()
	_test_other_actor_resolve_plays_nothing()
	_test_refuse_plays_nothing()
	_test_missing_host_emits_nothing()

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


func _test_resolve_after_the_real_frame_order() -> void:
	_effects.clear()
	_net.ingest_text_frame(
		'{"cast_phase":{"id":3,"ability":"fireball","target":1000002,"phase":"begin"}}'
	)
	_net.ingest_text_frame(
		'{"casting":{"ability":"fireball","progress":38,"total":38}}'
	)
	# The server clears the cast bar before it spends the mana, which is the order
	# that used to swallow the pending cast and leave the target unflashed.
	_net.ingest_text_frame('{"casting":{"ability":"","progress":0,"total":0}}')
	_net.ingest_text_frame('{"mana":{"id":3,"mana":80,"max_mana":100}}')
	_check(_effects.size() == 0, "a cast bar clear and a mana spend play no effect")
	_net.ingest_text_frame(
		'{"cast_phase":{"id":3,"ability":"fireball","target":1000002,"phase":"resolve"}}'
	)
	_check(_effects.size() == 1, "the resolve plays one cast effect")
	if _effects.size() == 1:
		_check(_effects[0]["target"] == 1000002, "effect targets the fireball dummy")
		_check(_effects[0]["ability"] == "fireball", "effect names fireball")
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


func _test_self_target_plays_on_local() -> void:
	_effects.clear()
	var you := _session.own_id()
	_net.ingest_text_frame(
		'{"cast_phase":{"id":3,"ability":"heal","target":%d,"phase":"resolve"}}' % you
	)
	_check(_effects.size() == 1, "self heal plays one cast effect")
	if _effects.size() == 1:
		_check(_effects[0]["target"] == you, "self heal targets own id")
	var local_avatar: Node3D = _session.get("_local")
	_check(local_avatar != null, "local avatar exists")
	if local_avatar != null:
		_check(
			local_avatar.get_node_or_null("CastHitFx") != null,
			"flash parents under local avatar for self target",
		)


func _test_begin_and_cancel_play_nothing() -> void:
	_effects.clear()
	_net.ingest_text_frame(
		'{"cast_phase":{"id":3,"ability":"fireball","target":1000002,"phase":"begin"}}'
	)
	_check(_effects.size() == 0, "a begin frame plays no effect")
	_net.ingest_text_frame(
		'{"cast_phase":{"id":3,"ability":"fireball","target":1000002,"phase":"cancel"}}'
	)
	_check(_effects.size() == 0, "a cancelled cast plays no effect")


func _test_other_actor_resolve_plays_nothing() -> void:
	_effects.clear()
	_net.ingest_text_frame(
		'{"cast_phase":{"id":1000002,"ability":"fireball","target":3,"phase":"resolve"}}'
	)
	_check(_effects.size() == 0, "another actor's resolve plays no local effect")


func _test_refuse_plays_nothing() -> void:
	_effects.clear()
	_net.ingest_text_frame('{"error":{"re":"cast","msg":"target out of range"}}')
	_check(_effects.size() == 0, "refused cast plays no effect")


func _test_missing_host_emits_nothing() -> void:
	_effects.clear()
	_net.ingest_text_frame(
		'{"cast_phase":{"id":3,"ability":"fireball","target":999999,"phase":"resolve"}}'
	)
	_check(_effects.size() == 0, "missing target host emits no cast_effect_played")


func _check(cond: bool, msg: String) -> void:
	_assertions.check(cond, msg)
