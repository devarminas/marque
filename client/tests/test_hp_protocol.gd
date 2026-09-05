extends RefCounted

const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.welcomed.connect(_on_welcomed)
		net.hp_changed.connect(_on_hp_changed)
		net.spawned.connect(_on_spawned)
		net.unknown_message.connect(_on_unknown)

	func feed(text: String) -> void:
		net.ingest_text_frame(text)

	func clear() -> void:
		events.clear()

	func of(signal_name: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for event in events:
			if event["signal"] == signal_name:
				out.append(event)
		return out

	func names() -> Array:
		var out := []
		for event in events:
			out.append(event["signal"])
		return out

	func release() -> void:
		net.free()

	func _on_welcomed(
		_you: int,
		_tick_ms: int,
		_tick: int,
		_heartbeat_ticks: int,
		_player_ids: PackedInt64Array,
		_player_positions: PackedVector2Array,
	) -> void:
		events.append({"signal": "welcomed"})

	func _on_hp_changed(id: int, hp: int, max_hp: int) -> void:
		events.append({"signal": "hp_changed", "id": id, "hp": hp, "max_hp": max_hp})

	func _on_spawned(id: int, _position: Vector2) -> void:
		events.append({"signal": "spawned", "id": id})

	func _on_unknown(key: String) -> void:
		events.append({"signal": "unknown_message", "key": key})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions
	print("== hp protocol: welcome, spawn, live hp, respawn frame ==")
	_test_welcome_emits_hp_after_welcomed()
	_test_live_hp_frame()
	_test_spawn_carries_hp()
	_test_respawn_frame()
	_test_pre_m5a_welcome_skips_hp()
	assertions.finish()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition


func _test_welcome_emits_hp_after_welcomed() -> void:
	var rec := Recorder.new()
	rec.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100},'
		+ '{"id":2,"x":5,"z":5,"hp":70,"max_hp":100}]}}'
	)
	_check(
		rec.names() == ["welcomed", "hp_changed", "hp_changed"],
		"welcome emits hp after welcomed, got %s" % [rec.names()],
	)
	var hps := rec.of("hp_changed")
	if _check(hps.size() == 2, "welcome carries two hp_changed events"):
		_check(hps[0]["id"] == 1 and hps[0]["hp"] == 100, "first hp is self at 100")
		_check(hps[1]["id"] == 2 and hps[1]["hp"] == 70, "second hp is other at 70")
	rec.release()


func _test_live_hp_frame() -> void:
	var rec := Recorder.new()
	rec.feed('{"hp":{"id":1,"hp":70,"max_hp":100}}')
	var hps := rec.of("hp_changed")
	if _check(hps.size() == 1, "a live hp frame emits once"):
		_check(
			hps[0]["id"] == 1 and hps[0]["hp"] == 70 and hps[0]["max_hp"] == 100,
			"live hp carries id/hp/max_hp, got %s" % [hps[0]],
		)
	rec.release()


func _test_spawn_carries_hp() -> void:
	var rec := Recorder.new()
	rec.feed('{"spawn":{"id":3,"x":1,"z":2,"hp":100,"max_hp":100}}')
	_check(
		rec.names() == ["spawned", "hp_changed"],
		"spawn emits hp after spawned, got %s" % [rec.names()],
	)
	var hps := rec.of("hp_changed")
	_check(hps.size() == 1 and hps[0]["hp"] == 100, "spawn hp is full")
	rec.release()


func _test_respawn_frame() -> void:
	var frame := NetClientScript.respawn_frame()
	_check(frame == {"respawn": {}}, "respawn_frame is {\"respawn\":{}}, got %s" % [frame])
	var sequenced := NetClientScript.respawn_frame(4)
	_check(
		sequenced == {"respawn": {"seq": 4}},
		"respawn_frame stamps seq when asked, got %s" % [sequenced],
	)


func _test_pre_m5a_welcome_skips_hp() -> void:
	var rec := Recorder.new()
	rec.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,'
		+ '"players":[{"id":1,"x":0,"z":0}]}}'
	)
	_check(rec.of("hp_changed").is_empty(), "a pre-M5a welcome emits no hp")
	_check(rec.of("welcomed").size() == 1, "and still joins")
	rec.release()
