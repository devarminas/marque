extends RefCounted

const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.skills_changed.connect(_on_skills_changed)

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

	func _on_skills_changed(
		player: int, skill_ids: PackedStringArray, levels: PackedInt32Array
	) -> void:
		events.append({
			"signal": "skills_changed",
			"player": player,
			"skill_ids": skill_ids,
			"levels": levels,
		})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions
	print("== skills protocol: full restatement per player ==")
	_test_active_skills_frame()
	_test_malformed_skills_array()
	_test_malformed_entry()
	_test_missing_level()
	assertions.finish()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition


func _test_active_skills_frame() -> void:
	var rec := Recorder.new()
	rec.feed(
		'{"skills":{"player":1,"skills":[{"id":"mining","xp":3300,"level":34},'
		+ '{"id":"woodcutting","xp":120,"level":2}]}}'
	)
	var events := rec.of("skills_changed")
	if _check(events.size() == 1, "a skills frame emits once"):
		var event: Dictionary = events[0]
		_check(event["player"] == 1, "player is 1")
		_check(
			event["skill_ids"] == PackedStringArray(["mining", "woodcutting"]),
			"skill ids parsed, got %s" % [event["skill_ids"]],
		)
		_check(
			event["levels"] == PackedInt32Array([34, 2]),
			"levels parsed, got %s" % [event["levels"]],
		)
	rec.release()


func _test_malformed_skills_array() -> void:
	var rec := Recorder.new()
	rec.feed('{"skills":{"player":1,"skills":"mining"}}')
	_check(rec.of("skills_changed").is_empty(), "non-array skills is rejected")
	rec.release()


func _test_malformed_entry() -> void:
	var rec := Recorder.new()
	rec.feed('{"skills":{"player":1,"skills":["mining"]}}')
	_check(rec.of("skills_changed").is_empty(), "non-object skills entry is rejected")
	rec.release()


func _test_missing_level() -> void:
	var rec := Recorder.new()
	rec.feed('{"skills":{"player":1,"skills":[{"id":"mining","xp":0}]}}')
	_check(rec.of("skills_changed").is_empty(), "missing level is rejected")
	rec.release()
