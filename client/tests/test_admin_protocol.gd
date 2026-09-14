extends RefCounted


const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.admin_reply_received.connect(_on_admin_reply_received)
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

	func _on_admin_reply_received(reply_text: String) -> void:
		events.append({"signal": "admin_reply_received", "text": reply_text})

	func _on_unknown(key: String) -> void:
		events.append({"signal": "unknown_message", "key": key})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions
	print("== admin protocol: private reply decode and intent frame ==")
	_test_admin_reply_prefixes()
	_test_rejects_missing_text()
	_test_admin_intent_frame()
	assertions.finish()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition


func _test_admin_reply_prefixes() -> void:
	var rec := Recorder.new()
	rec.feed('{"admin_reply":{"text":"ok: noop ran"}}')
	_check(rec.names() == ["admin_reply_received"], "admin_reply emits admin_reply_received")
	var events := rec.of("admin_reply_received")
	if not events.is_empty():
		_check(events[0]["text"] == "ok: noop ran", "ok text is preserved")
	rec.clear()
	rec.feed('{"admin_reply":{"text":"deny: unauthorized"}}')
	events = rec.of("admin_reply_received")
	_check(
		not events.is_empty() and events[0]["text"] == "deny: unauthorized",
		"deny text is preserved",
	)
	rec.clear()
	rec.feed('{"admin_reply":{"text":"usage: unknown command nope"}}')
	events = rec.of("admin_reply_received")
	_check(
		not events.is_empty() and str(events[0]["text"]).begins_with("usage: "),
		"usage text is preserved",
	)
	rec.release()


func _test_rejects_missing_text() -> void:
	var rec := Recorder.new()
	rec.feed('{"admin_reply":{}}')
	_check(rec.names().is_empty(), "missing text emits nothing, got %s" % [rec.names()])
	rec.release()


func _test_admin_intent_frame() -> void:
	var frame := NetClientScript.admin_frame("/help", 3)
	_check(
		frame == {"admin": {"line": "/help", "seq": 3}},
		"admin frame carries line and seq, got %s" % [frame],
	)
