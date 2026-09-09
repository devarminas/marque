extends RefCounted


const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.quest_log_changed.connect(_on_quest_log_changed)
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

	func _on_quest_log_changed(
		ids: PackedStringArray,
		titles: PackedStringArray,
		objectives: PackedStringArray,
		statuses: PackedStringArray,
	) -> void:
		events.append({
			"signal": "quest_log_changed",
			"ids": ids,
			"titles": titles,
			"objectives": objectives,
			"statuses": statuses,
		})

	func _on_unknown(key: String) -> void:
		events.append({"signal": "unknown_message", "key": key})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions
	print("== quest log protocol: restatement parse ==")
	_test_empty_quest_log()
	_test_active_quest_frame()
	_test_rejects_bad_status()
	_test_rejects_duplicate_ids()
	assertions.finish()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition


func _test_empty_quest_log() -> void:
	var rec := Recorder.new()
	rec.feed('{"quest_log":{"quests":[]}}')
	_check(rec.names() == ["quest_log_changed"], "empty quest_log emits quest_log_changed")
	var events := rec.of("quest_log_changed")
	if not events.is_empty():
		_check(
			(events[0]["ids"] as PackedStringArray).is_empty(),
			"empty quests restates as zero entries",
		)
	rec.release()


func _test_active_quest_frame() -> void:
	var rec := Recorder.new()
	rec.feed(
		'{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring Sticks",'
		+ '"objective":"Deliver 1 sticks","status":"active"}]}}'
	)
	_check(rec.names() == ["quest_log_changed"], "quest_log emits quest_log_changed, got %s" % [rec.names()])
	var events := rec.of("quest_log_changed")
	if events.is_empty():
		rec.release()
		return
	var event: Dictionary = events[0]
	_check(
		event["ids"] == PackedStringArray(["bring_a_stick"]),
		"quest id is server id, got %s" % [event["ids"]],
	)
	_check(
		event["titles"] == PackedStringArray(["Bring Sticks"]),
		"title is server text, got %s" % [event["titles"]],
	)
	_check(
		event["objectives"] == PackedStringArray(["Deliver 1 sticks"]),
		"objective is server text, got %s" % [event["objectives"]],
	)
	_check(
		event["statuses"] == PackedStringArray(["active"]),
		"status is server status, got %s" % [event["statuses"]],
	)
	rec.release()


func _test_rejects_bad_status() -> void:
	var rec := Recorder.new()
	rec.feed(
		'{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring Sticks",'
		+ '"objective":"Deliver 1 sticks","status":"pending"}]}}'
	)
	_check(rec.names().is_empty(), "a non-wire status emits nothing, got %s" % [rec.names()])
	rec.release()


func _test_rejects_duplicate_ids() -> void:
	var rec := Recorder.new()
	rec.feed(
		'{"quest_log":{"quests":['
		+ '{"id":"bring_a_stick","title":"A","objective":"o","status":"active"},'
		+ '{"id":"bring_a_stick","title":"B","objective":"o","status":"complete"}'
		+ ']}}'
	)
	_check(rec.names().is_empty(), "duplicate quest ids emit nothing, got %s" % [rec.names()])
	rec.release()
