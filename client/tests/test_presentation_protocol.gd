extends RefCounted

const Assertions := preload("res://tests/assertions.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.welcomed.connect(func(_you, _tick_ms, _tick, _hb, _ids, _positions) -> void: events.append({"signal": "welcomed"}))
		net.spawned.connect(func(id: int, _position: Vector2) -> void: events.append({"signal": "spawned", "id": id}))
		net.worn_changed.connect(
			func(id: int, names: PackedStringArray, kinds: PackedStringArray) -> void:
				events.append({"signal": "worn_changed", "id": id, "names": names, "kinds": kinds})
		)
		net.swing_observed.connect(
			func(id: int, target: int, weapon: String) -> void:
				events.append({"signal": "swing_observed", "id": id, "target": target, "weapon": weapon})
		)
		net.swing_hit_observed.connect(
			func(id: int, amount: int, crit: bool, miss: bool) -> void:
				events.append({"signal": "swing_hit_observed", "id": id, "amount": amount, "crit": crit, "miss": miss})
		)
		net.cast_phase_observed.connect(
			func(id: int, ability: String, target: int, phase: String) -> void:
				events.append({"signal": "cast_phase_observed", "id": id, "ability": ability, "target": target, "phase": phase})
		)
		net.cast_effect_observed.connect(
			func(id: int, amount: int, effect: String) -> void:
				events.append({"signal": "cast_effect_observed", "id": id, "amount": amount, "effect": effect})
		)
		net.gather_observed.connect(
			func(id: int, node: int) -> void: events.append({"signal": "gather_observed", "id": id, "node": node})
		)
		net.unknown_message.connect(func(key: String) -> void: events.append({"signal": "unknown_message", "key": key}))

	func feed(text: String) -> Array[Dictionary]:
		events.clear()
		net.ingest_text_frame(text)
		return events

	func release() -> void:
		net.free()


func run(assertions: Assertions) -> void:
	var recorder := Recorder.new()
	_test_swing(assertions, recorder)
	_test_cast_phase_and_gather_parse_without_warning(assertions, recorder)
	_test_worn_broadcast(assertions, recorder)
	_test_welcome_and_spawn_carry_worn(assertions, recorder)
	recorder.release()
	assertions.finish()


func _test_swing(assertions: Assertions, recorder: Recorder) -> void:
	var events := recorder.feed(
		'{"swing":{"id":7,"target":1000004,"weapon":"sword","amount":9,"crit":true,"miss":false}}'
	)
	assertions.check(
		events == [
			{"signal": "swing_observed", "id": 7, "target": 1000004, "weapon": "sword"},
			{"signal": "swing_hit_observed", "id": 7, "amount": 9, "crit": true, "miss": false},
		],
		"a swing frame emits swing_observed then swing_hit_observed, got %s" % [events],
	)
	events = recorder.feed('{"swing":{"id":7,"target":1000004,"weapon":"sword"}}')
	assertions.check(
		events == [{"signal": "swing_observed", "id": 7, "target": 1000004, "weapon": "sword"}],
		"a swing without the hit facts still animates and forwards nothing extra, got %s" % [events],
	)
	events = recorder.feed(
		'{"swing":{"id":7,"target":1000004,"weapon":"sword","amount":0,"crit":false,"miss":true}}'
	)
	assertions.check(
		events == [
			{"signal": "swing_observed", "id": 7, "target": 1000004, "weapon": "sword"},
			{"signal": "swing_hit_observed", "id": 7, "amount": 0, "crit": false, "miss": true},
		],
		"a swing frame reporting a miss carries miss=true, got %s" % [events],
	)
	print("  (the ERROR line below is a fail-closed path under test)")
	events = recorder.feed('{"swing":{"id":7,"target":1000004}}')
	assertions.check(events.is_empty(), "a swing without a weapon emits nothing, got %s" % [events])


func _test_cast_phase_and_gather_parse_without_warning(assertions: Assertions, recorder: Recorder) -> void:
	for phase in ["begin", "cancel"]:
		var events := recorder.feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":7,"phase":"%s"}}' % phase)
		assertions.check(
			events == [{"signal": "cast_phase_observed", "id": 1000004, "ability": "fireball", "target": 7, "phase": phase}],
			"cast_phase %s parses as a known message and forwards no effect facts, got %s" % [phase, events],
		)
	var resolve := recorder.feed(
		'{"cast_phase":{"id":1000004,"ability":"fireball","target":7,"phase":"resolve","amount":22,"effect":"damage"}}'
	)
	assertions.check(
		resolve == [
			{"signal": "cast_phase_observed", "id": 1000004, "ability": "fireball", "target": 7, "phase": "resolve"},
			{"signal": "cast_effect_observed", "id": 1000004, "amount": 22, "effect": "damage"},
		],
		"a resolve frame forwards its amount and effect, got %s" % [resolve],
	)
	var zero_delta := recorder.feed(
		'{"cast_phase":{"id":1000004,"ability":"heal","target":7,"phase":"resolve","effect":"heal"}}'
	)
	assertions.check(
		zero_delta == [
			{"signal": "cast_phase_observed", "id": 1000004, "ability": "heal", "target": 7, "phase": "resolve"},
			{"signal": "cast_effect_observed", "id": 1000004, "amount": 0, "effect": "heal"},
		],
		"a resolve that moved no HP omits amount and still forwards its effect, got %s" % [zero_delta],
	)
	# An absent amount means the applied delta was zero, so ARM-315 renders no float
	# for it. The wire carries no sentinel for the case and the client adds none.
	var explicit_zero := recorder.feed(
		'{"cast_phase":{"id":1000004,"ability":"heal","target":7,"phase":"resolve","amount":0,"effect":"heal"}}'
	)
	assertions.check(
		explicit_zero == [
			{"signal": "cast_phase_observed", "id": 1000004, "ability": "heal", "target": 7, "phase": "resolve"},
			{"signal": "cast_effect_observed", "id": 1000004, "amount": 0, "effect": "heal"},
		] and explicit_zero == zero_delta,
		"a resolve that omits amount and one that says 0 are the same fact for ARM-315, which floats no number for either, got %s and %s" % [zero_delta, explicit_zero],
	)
	print("  (the ERROR line below is a fail-closed path under test)")
	var bad := recorder.feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":7,"phase":"windup"}}')
	assertions.check(bad.is_empty(), "an unknown cast phase emits nothing, got %s" % [bad])
	var gather := recorder.feed('{"gather":{"id":7,"node":12}}')
	assertions.check(
		gather == [{"signal": "gather_observed", "id": 7, "node": 12}],
		"a gather frame parses as a known message, got %s" % [gather],
	)


func _test_worn_broadcast(assertions: Assertions, recorder: Recorder) -> void:
	var events := recorder.feed(
		'{"worn":{"id":9,"slots":[{"slot":"helmet","kind":"plate_helm"},{"slot":"right hand","kind":"sword"}]}}'
	)
	assertions.check(
		events.size() == 1
		and events[0]["signal"] == "worn_changed"
		and events[0]["id"] == 9
		and events[0]["names"] == PackedStringArray(["helmet", "right hand"])
		and events[0]["kinds"] == PackedStringArray(["plate_helm", "sword"]),
		"a worn frame emits worn_changed with its slot names and kinds, got %s" % [events],
	)
	events = recorder.feed('{"worn":{"id":9,"slots":null}}')
	assertions.check(
		events.size() == 1 and events[0]["names"].is_empty() and events[0]["kinds"].is_empty(),
		"a null slots list restates bare, got %s" % [events],
	)
	print("  (the ERROR line below is a fail-closed path under test)")
	events = recorder.feed('{"worn":{"id":9,"slots":[{"slot":"helmet"}]}}')
	assertions.check(events.is_empty(), "a slot without a kind emits nothing, got %s" % [events])


func _test_welcome_and_spawn_carry_worn(assertions: Assertions, recorder: Recorder) -> void:
	var events := recorder.feed(
		'{"welcome":{"you":1,"tick_ms":40,"tick":1,"heartbeat_ticks":10,"players":['
		+ '{"id":1,"x":0,"z":0,"worn":[]},'
		+ '{"id":2,"x":1,"z":1,"worn":[{"slot":"chest","kind":"cloth_robe"}]},'
		+ '{"id":3,"x":2,"z":2}'
		+ ']}}'
	)
	var names := events.map(func(event: Dictionary) -> String: return event["signal"])
	assertions.check(
		names == ["welcomed", "worn_changed", "worn_changed"],
		"welcome emits worn_changed after welcomed for each player that carries worn, got %s" % [names],
	)
	if names.size() == 3:
		assertions.check(
			events[1]["id"] == 1 and events[1]["names"].is_empty() and events[2]["id"] == 2 and events[2]["kinds"] == PackedStringArray(["cloth_robe"]),
			"and each carries that player's slots, got %s" % [events],
		)
	events = recorder.feed('{"spawn":{"id":4,"x":3,"z":3,"worn":[{"slot":"feet","kind":"prospector_boots"}]}}')
	names = events.map(func(event: Dictionary) -> String: return event["signal"])
	assertions.check(names == ["spawned", "worn_changed"], "spawn emits worn_changed after spawned, got %s" % [names])
