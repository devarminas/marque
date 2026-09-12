extends RefCounted


const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.dialog_changed.connect(_on_dialog_changed)
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

	func _on_dialog_changed(
		npc_id: int, lines: PackedStringArray, option_ids: PackedStringArray
	) -> void:
		events.append({
			"signal": "dialog_changed",
			"npc": npc_id,
			"lines": lines,
			"options": option_ids,
		})

	func _on_unknown(key: String) -> void:
		events.append({"signal": "unknown_message", "key": key})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions
	print("== dialog protocol: restatement parse and talk/dialog_option frames ==")
	_test_open_dialog_frame()
	_test_close_dialog_frame()
	_test_rejects_bad_options()
	_test_talk_and_dialog_option_frames()
	_test_welcome_accepts_neutral_quest_giver()
	assertions.finish()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition


func _test_open_dialog_frame() -> void:
	var rec := Recorder.new()
	rec.feed(
		'{"dialog":{"npc":1000003,"lines":["Will you accept Bring Sticks?"],'
		+ '"options":[{"id":"accept_quest"},{"id":"stop_talking"}]}}'
	)
	_check(rec.names() == ["dialog_changed"], "open dialog emits dialog_changed, got %s" % [rec.names()])
	var events := rec.of("dialog_changed")
	if events.is_empty():
		rec.release()
		return
	var event: Dictionary = events[0]
	_check(event["npc"] == 1000003, "dialog.npc is 1000003, got %s" % event["npc"])
	_check(
		event["lines"] == PackedStringArray(["Will you accept Bring Sticks?"]),
		"dialog.lines are server text, got %s" % [event["lines"]],
	)
	_check(
		event["options"] == PackedStringArray(["accept_quest", "stop_talking"]),
		"dialog.options are option ids, got %s" % [event["options"]],
	)
	rec.release()


func _test_close_dialog_frame() -> void:
	var rec := Recorder.new()
	rec.feed('{"dialog":{"npc":1000003,"lines":[],"options":[]}}')
	_check(rec.names() == ["dialog_changed"], "empty dialog still emits dialog_changed")
	var events := rec.of("dialog_changed")
	if not events.is_empty():
		_check(
			(events[0]["lines"] as PackedStringArray).is_empty()
			and (events[0]["options"] as PackedStringArray).is_empty(),
			"empty lines and options close the dialog",
		)
	rec.release()


func _test_rejects_bad_options() -> void:
	var rec := Recorder.new()
	rec.feed('{"dialog":{"npc":1000003,"lines":["hi"],"options":[{"id":"accept_quest"},"nope"]}}')
	_check(rec.names().is_empty(), "a non-object option emits nothing, got %s" % [rec.names()])
	rec.release()


func _test_talk_and_dialog_option_frames() -> void:
	_check(
		JSON.stringify(NetClientScript.talk_frame(1000003)) == '{"talk":{"npc":1000003}}',
		"talk frame names the npc",
	)
	_check(
		(
			JSON.stringify(NetClientScript.dialog_option_frame(1000003, "accept_quest"))
			== '{"dialog_option":{"npc":1000003,"option":"accept_quest"}}'
		),
		"dialog_option frame names npc and option",
	)
	_check(
		(
			JSON.stringify(NetClientScript.dialog_option_frame(1000003, "stop_talking"))
			== '{"dialog_option":{"npc":1000003,"option":"stop_talking"}}'
		),
		"stop_talking is a dialog_option id",
	)


func _test_welcome_accepts_neutral_quest_giver() -> void:
	var rec := Recorder.new()
	rec.net.welcome_npcs.connect(
		func(
			npc_ids: PackedInt64Array,
			npc_kinds: PackedStringArray,
			npc_factions: PackedStringArray,
			_names: PackedStringArray,
			_pos: PackedVector2Array,
			_hps: PackedInt32Array,
			_max_hps: PackedInt32Array,
		) -> void:
			rec.events.append({
				"signal": "welcome_npcs",
				"ids": npc_ids,
				"kinds": npc_kinds,
				"factions": npc_factions,
			})
	)
	rec.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],"items":[],"nodes":[],'
		+ '"npcs":[{"id":1000003,"kind":"quest_giver","faction":"neutral","x":2.0,"z":0.0,'
		+ '"hp":100,"max_hp":100}]}}'
	)
	var npcs := rec.of("welcome_npcs")
	_check(npcs.size() == 1, "neutral quest_giver survives welcome parse")
	if not npcs.is_empty():
		_check(
			Array(npcs[0]["factions"]) == ["neutral"] and Array(npcs[0]["kinds"]) == ["quest_giver"],
			"with faction neutral and kind quest_giver, got %s / %s"
			% [Array(npcs[0]["factions"]), Array(npcs[0]["kinds"])],
		)
	rec.release()
