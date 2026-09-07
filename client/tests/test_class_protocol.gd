extends RefCounted

const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.class_changed.connect(_on_class_changed)

	func feed(text: String) -> void:
		net.ingest_text_frame(text)

	func of(signal_name: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for event in events:
			if event["signal"] == signal_name:
				out.append(event)
		return out

	func release() -> void:
		net.free()

	func _on_class_changed(
		player: int,
		class_id: String,
		missing_slot_names: PackedStringArray,
		missing_slot_kinds: PackedStringArray,
		missing_tools: PackedStringArray,
	) -> void:
		events.append({
			"signal": "class_changed",
			"player": player,
			"class_id": class_id,
			"missing_slot_names": missing_slot_names,
			"missing_slot_kinds": missing_slot_kinds,
			"missing_tools": missing_tools,
		})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions
	print("== class protocol: active, inactive, missing pieces ==")
	_test_active_class_frame()
	_test_inactive_class_frame()
	_test_missing_pieces()
	_test_other_player_ignored_by_session_is_net_only()
	_test_malformed_class_string()
	_test_malformed_missing_slots()
	assertions.finish()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition


func _test_active_class_frame() -> void:
	var rec := Recorder.new()
	rec.feed('{"class":{"player":1,"class":"miner"}}')
	var events := rec.of("class_changed")
	if _check(events.size() == 1, "an active class frame emits once"):
		_check(events[0]["player"] == 1, "player is 1")
		_check(events[0]["class_id"] == "miner", 'class_id is "miner"')
		_check(events[0]["missing_slot_names"].is_empty(), "no missing slots")
		_check(events[0]["missing_tools"].is_empty(), "no missing tools")
	rec.release()


func _test_inactive_class_frame() -> void:
	var rec := Recorder.new()
	rec.feed('{"class":{"player":1,"class":""}}')
	var events := rec.of("class_changed")
	if _check(events.size() == 1, "an inactive class frame emits once"):
		_check(events[0]["class_id"] == "", 'class_id is ""')
		_check(events[0]["missing_slot_names"].is_empty(), "missing slots default empty")
	rec.release()


func _test_missing_pieces() -> void:
	var rec := Recorder.new()
	rec.feed(
		'{"class":{"player":1,"class":"","missing":{"slots":[{"slot":"helmet","kind":"plate_helm"}],'
		+ '"tools":["pickaxe"]}}}'
	)
	var events := rec.of("class_changed")
	if _check(events.size() == 1, "a partial class frame emits once"):
		var event: Dictionary = events[0]
		_check(event["class_id"] == "", 'class_id is "" when partial')
		_check(
			event["missing_slot_names"] == PackedStringArray(["helmet"]),
			"missing slot names parsed, got %s" % [event["missing_slot_names"]],
		)
		_check(
			event["missing_slot_kinds"] == PackedStringArray(["plate_helm"]),
			"missing slot kinds parsed, got %s" % [event["missing_slot_kinds"]],
		)
		_check(
			event["missing_tools"] == PackedStringArray(["pickaxe"]),
			"missing tools parsed, got %s" % [event["missing_tools"]],
		)
	rec.release()


func _test_other_player_ignored_by_session_is_net_only() -> void:
	var rec := Recorder.new()
	rec.feed('{"class":{"player":2,"class":"knight"}}')
	var events := rec.of("class_changed")
	if _check(events.size() == 1, "net_client emits class for any player id"):
		_check(events[0]["player"] == 2, "player id is preserved")
	rec.release()


func _test_malformed_class_string() -> void:
	var rec := Recorder.new()
	rec.feed('{"class":{"player":1,"class":3}}')
	_check(rec.of("class_changed").is_empty(), "non-string class is rejected")
	rec.release()


func _test_malformed_missing_slots() -> void:
	var rec := Recorder.new()
	rec.feed('{"class":{"player":1,"class":"","missing":{"slots":"helmet","tools":[]}}}')
	_check(rec.of("class_changed").is_empty(), "non-array missing.slots is rejected")
	rec.release()
