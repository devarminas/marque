extends RefCounted

## The heartbeat's wire layer: frames fed to [code]net_client.gd[/code]'s public
## [code]ingest_text_frame[/code], no scene tree and no server. **M2c.**
##
## What the heartbeat does to a session is the other half, and lives in
## [code]test_heartbeat.gd[/code], which needs a tree because the session does.

const NetClientScript := preload("res://scripts/net_client.gd")


## One client and everything it emitted, in order.
class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.welcomed.connect(_on_welcomed)
		net.tick_received.connect(_on_tick_received)
		net.spawned.connect(_on_spawned)
		net.unknown_message.connect(_on_unknown_message)
		net.disconnected.connect(_on_disconnected)

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
		you: int,
		tick_ms: int,
		tick: int,
		heartbeat_ticks: int,
		_player_ids: PackedInt64Array,
		_player_positions: PackedVector2Array,
	) -> void:
		events.append({
			"signal": "welcomed",
			"you": you,
			"tick_ms": tick_ms,
			"tick": tick,
			"heartbeat_ticks": heartbeat_ticks,
		})

	func _on_tick_received(t: int) -> void:
		events.append({"signal": "tick_received", "t": t})

	func _on_spawned(id: int, spawn_position: Vector2) -> void:
		events.append({"signal": "spawned", "id": id, "position": spawn_position})

	func _on_unknown_message(key: String) -> void:
		events.append({"signal": "unknown_message", "key": key})

	func _on_disconnected(code: int, reason: String) -> void:
		events.append({"signal": "disconnected", "code": code, "reason": reason})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions

	_test_tick_decodes_to_an_integer()
	_test_tick_is_no_longer_an_unknown_key()
	_test_a_tick_with_no_readable_t_is_dropped()
	_test_welcome_carries_heartbeat_ticks()
	_test_an_unusable_heartbeat_ticks_reads_as_zero_without_losing_the_welcome()
	_test_abandon_drops_the_transport_and_reports_it()

	assertions.finish()


func _test_tick_decodes_to_an_integer() -> void:
	var recorder := Recorder.new()
	recorder.feed('{"tick":{"t":9001}}')
	var ticks := recorder.of("tick_received")
	if _check(ticks.size() == 1, "tick emits once, got %d" % ticks.size()):
		_check(ticks[0]["t"] == 9001, "carrying t, got %s" % ticks[0]["t"])
		_check(
			typeof(ticks[0]["t"]) == TYPE_INT,
			"as an int and not the float JSON hands back, got type %d" % typeof(ticks[0]["t"]),
		)

	recorder.clear()
	recorder.feed('{"tick":{"t":12,"sent_at":"anything"}}')
	_check(
		recorder.of("tick_received").size() == 1,
		"tick decodes past an unknown field in its body",
	)
	recorder.release()


func _test_tick_is_no_longer_an_unknown_key() -> void:
	var recorder := Recorder.new()
	recorder.feed('{"tick":{"t":1}}')
	_check(
		recorder.names() == ["tick_received"],
		"tick emits only tick_received, got %s" % [recorder.names()],
	)

	recorder.clear()
	recorder.feed('{"m2c_no_such_message":{"t":1}}')
	var unknown := recorder.of("unknown_message")
	if _check(unknown.size() == 1, "an invented key is still reported as unknown"):
		_check(
			unknown[0]["key"] == "m2c_no_such_message",
			"naming it, got %s" % unknown[0]["key"],
		)
	_check(
		recorder.of("disconnected").is_empty(),
		"and an unknown key is still not a reason to close",
	)
	recorder.release()


func _test_a_tick_with_no_readable_t_is_dropped() -> void:
	var recorder := Recorder.new()
	var bad := [
		'{"tick":{}}',
		'{"tick":{"t":"x"}}',
		'{"tick":{"t":null}}',
		'{"tick":{"tick":5}}',
		'{"tick":[5]}',
		'{"tick":5}',
	]
	for frame: String in bad:
		recorder.clear()
		recorder.feed(frame)
		_check(recorder.events.is_empty(), "a malformed tick emits nothing: %s" % frame)

	recorder.clear()
	recorder.feed('{"spawn":{"id":4,"x":1.0,"z":2.0}}')
	_check(
		recorder.of("spawned").size() == 1,
		"and the next good frame still decodes, so the connection was kept",
	)
	_check(
		recorder.of("disconnected").is_empty(),
		"a malformed tick never closes the connection",
	)
	recorder.release()


func _test_welcome_carries_heartbeat_ticks() -> void:
	var recorder := Recorder.new()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":100,"heartbeat_ticks":2,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}]}}'
	)
	var welcomes := recorder.of("welcomed")
	if _check(welcomes.size() == 1, "welcome decodes"):
		_check(
			welcomes[0]["heartbeat_ticks"] == 2,
			"heartbeat_ticks reaches the listener, got %s" % welcomes[0]["heartbeat_ticks"],
		)
		_check(
			typeof(welcomes[0]["heartbeat_ticks"]) == TYPE_INT,
			"as an int, got type %d" % typeof(welcomes[0]["heartbeat_ticks"]),
		)

	recorder.clear()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":100,"players":[{"id":1,"x":0.0,"z":0.0}]}}'
	)
	var absent := recorder.of("welcomed")
	if _check(absent.size() == 1, "a welcome with no heartbeat_ticks is still a welcome"):
		_check(
			absent[0]["heartbeat_ticks"] == 0,
			"and reads as 0, which is liveness off, got %s" % absent[0]["heartbeat_ticks"],
		)

	recorder.clear()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":100,"heartbeat_ticks":0,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}]}}'
	)
	_check(
		(recorder.of("welcomed")[0] as Dictionary)["heartbeat_ticks"] == 0,
		"an explicit 0 means the same thing as an absent key",
	)
	recorder.release()


func _test_an_unusable_heartbeat_ticks_reads_as_zero_without_losing_the_welcome() -> void:
	var recorder := Recorder.new()
	var unusable := ['"soon"', "-1", "null", "[2]"]
	for value: String in unusable:
		recorder.clear()
		recorder.feed(
			'{"welcome":{"you":3,"tick_ms":150,"tick":100,"heartbeat_ticks":' + value
			+ ',"players":[{"id":3,"x":0.0,"z":0.0}]}}'
		)
		var welcomes := recorder.of("welcomed")
		if _check(
			welcomes.size() == 1,
			"heartbeat_ticks %s does not cost the welcome" % value,
		):
			_check(
				welcomes[0]["heartbeat_ticks"] == 0,
				"and reads as 0, got %s" % welcomes[0]["heartbeat_ticks"],
			)
			_check(
				welcomes[0]["you"] == 3 and welcomes[0]["tick"] == 100,
				"and the rest of the welcome lands unchanged",
			)
	recorder.release()


## Whether the transport really goes without a close frame is a claim about
## [WebSocketPeer] that only a server can settle; `test_interop.gd`'s live half
## is where it is settled. What is left to assert here is the reporting.
func _test_abandon_drops_the_transport_and_reports_it() -> void:
	var recorder := Recorder.new()
	_check(not recorder.net.is_open(), "a client with no socket is not open")

	recorder.net.abandon()
	var closes := recorder.of("disconnected")
	if _check(
		closes.size() == 1,
		"abandon() emits disconnected without waiting for a frame, got %d" % closes.size(),
	):
		_check(
			closes[0]["code"] == 0 and closes[0]["reason"] == "",
			"reporting no close code and no reason, because no close frame was sent",
		)
	_check(not recorder.net.is_open(), "and the client is not open afterwards")

	recorder.clear()
	recorder.net.abandon()
	_check(
		recorder.of("disconnected").is_empty(),
		"a second abandon() reports nothing; the session ends once",
	)
	recorder.release()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition
