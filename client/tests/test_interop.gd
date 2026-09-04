extends Node

## Godot-to-Go interop: real `marqued`, real sockets, real frames.
##
## Everything here runs against a live server process. Nothing is stubbed and
## nothing is mocked, because the assumption this unit exists to retire is
## exactly the one a mock would assume away: that Godot's [WebSocketPeer] and
## the Go server can talk to each other at all.
##
## Two halves. The [b]decoding[/b] half needs nothing and always runs: frames
## are handed to the client by hand, which is also the only way to reach the
## shapes a conforming server never sends. The [b]live[/b] half needs a server,
## and skips loudly without one.
##
## [b]The live half's server[/b] must be freshly started with no other clients
## attached: it asserts on sequentially assigned player ids and on a world
## containing only its own clients. Its websocket URL comes from the environment
## variable named by [constant URL_ENV]. Run the whole thing with
##
## [codeblock]
## powershell -ExecutionPolicy Bypass -File scripts/interop_test.ps1
## [/codeblock]
##
## which builds the server, starts it on a free port, exports the variable, runs
## the suite, and shuts the server down. It also fails a run whose suite skipped,
## so that the plain [code]--script res://tests/run_tests.gd[/code] command can
## stay green without a server without that green ever being mistaken for
## interop having been tested.
##
## Reports through the runner's suite contract rather than quitting the tree.
## See `run_tests.gd`.

## Names the environment variable carrying the websocket URL.
const URL_ENV := "MARQUE_WS_URL"
const NetClientScript := preload("res://scripts/net_client.gd")

## Upper bound on any single wait for an expected frame. At the frame cap below
## this is about four seconds, which is three orders of magnitude more than a
## loopback round trip needs and still well inside the runner's watchdog.
const WAIT_FRAMES := 240

## Frame cap held for the duration of this suite.
##
## The runner's watchdog counts frames and the network costs wall-clock time, so
## the two are only commensurable if a frame has a known minimum duration.
## Uncapped, a fast machine burns the whole frame budget waiting on one
## handshake. Restored when the suite ends.
const MAX_FPS := 30

## Position tolerance in world units. Coordinates cross the wire as JSON decimal
## through float64 on both ends and land in a float32 [Vector2]; this absorbs
## that and nothing else. The expectations are exactly representable values.
const POSITION_EPSILON := 0.0005

## The server's tick, its walk speed, and its world bound. Duplicated from the
## server deliberately: a test that read them from the server could not detect
## the server getting them wrong.
const EXPECTED_TICK_MS := 150
const EXPECTED_SPEED := 3.0
const WORLD_HALF_EXTENT := 128.0

## Everyone spawns at the origin (`PROTOCOL.md` says ids and positions, the
## server says where).
const SPAWN_POSITION := Vector2(0.0, 0.0)

## A's first destination. Exactly representable in float32 and near enough that
## the walk finishes inside a fraction of a second.
const FIRST_DESTINATION := Vector2(0.75, 1.0)
## A's second destination, walked while B and then C are watching.
const SECOND_DESTINATION := Vector2(-2.0, 1.0)
## Outside `WORLD_HALF_EXTENT`, so the server must refuse it.
const OUT_OF_BOUNDS := Vector2(200.0, 0.0)

## Wall-clock milliseconds to let a walk finish before asserting the walker
## stopped. The first walk is 1.25 units at 3.0 u/s, so 417ms plus a tick of
## slack plus room for a stalled frame.
const ARRIVAL_WAIT_MSEC := 800
## Wall-clock milliseconds to let A get properly under way before C joins, so
## that C's replayed path is re-anchored somewhere strictly along the segment
## rather than still at its origin.
const MIDWALK_WAIT_MSEC := 450
## Wall-clock milliseconds to let the server read an abandoned socket: several
## ticks and a loopback round trip. The assertion that follows is that nothing
## arrived, so this is how long "nothing" means.
const ABANDON_SETTLE_MSEC := 1000


## One connected client and everything it has heard.
##
## The suite asserts on frames that have already arrived rather than awaiting
## each one, so an out-of-order or duplicated frame shows up as a wrong count
## instead of being silently consumed by a matching await.
class Peer:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var label: String
	var net: NetClientScript

	var opened := false
	var closed := false
	var close_code := 0

	var welcome := {}
	var welcomes: Array[Dictionary] = []
	var paths: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
	var spawns: Array[Dictionary] = []
	var despawns: Array[int] = []
	var inventories: Array[int] = []
	var unknown_keys := PackedStringArray()
	## Every `t` this peer was sent by a `tick` heartbeat, oldest first.
	var ticks: Array[int] = []

	func _init(peer_label: String) -> void:
		label = peer_label
		net = NetClientScript.new()
		net.name = "NetClient" + peer_label
		net.connected.connect(_on_connected)
		net.disconnected.connect(_on_disconnected)
		net.welcomed.connect(_on_welcomed)
		net.spawned.connect(_on_spawned)
		net.despawned.connect(_on_despawned)
		net.path_assigned.connect(_on_path_assigned)
		net.inventory_changed.connect(_on_inventory_changed)
		net.server_error.connect(_on_server_error)
		net.unknown_message.connect(_on_unknown_message)
		net.tick_received.connect(_on_tick_received)

	func _on_connected() -> void:
		opened = true

	func _on_disconnected(code: int, _reason: String) -> void:
		closed = true
		close_code = code

	func _on_welcomed(
		you: int,
		tick_ms: int,
		tick: int,
		heartbeat_ticks: int,
		player_ids: PackedInt64Array,
		player_positions: PackedVector2Array,
	) -> void:
		welcome = {
			"you": you,
			"tick_ms": tick_ms,
			"tick": tick,
			"heartbeat_ticks": heartbeat_ticks,
			"ids": player_ids,
			"positions": player_positions,
			"session": net.session_token(),
			# The clock anchor from PROTOCOL.md, "Clock": monotonic, never a
			# frame-delta accumulation.
			"at_msec": Time.get_ticks_msec(),
		}
		welcomes.append(welcome)

	func _on_inventory_changed(
		size: int, _slot_indices: PackedInt32Array, _slot_kinds: PackedStringArray
	) -> void:
		inventories.append(size)

	func reset_for_reconnect() -> void:
		opened = false
		closed = false
		welcome = {}

	func _on_spawned(id: int, position: Vector2) -> void:
		spawns.append({"id": id, "position": position})

	func _on_despawned(id: int) -> void:
		despawns.append(id)

	func _on_path_assigned(
		id: int, start_tick: int, points: PackedVector2Array, speed: float
	) -> void:
		paths.append({"id": id, "start_tick": start_tick, "points": points, "speed": speed})

	func _on_server_error(re: String, message: String) -> void:
		errors.append({"re": re, "msg": message})

	func _on_unknown_message(key: String) -> void:
		unknown_keys.append(key)

	func _on_tick_received(t: int) -> void:
		ticks.append(t)

	## The client's own estimate of the server's current tick, per
	## `PROTOCOL.md`, "Clock". Anchored to a monotonic clock, never accumulated
	## from frame deltas, so a stalled frame cannot make it fall behind.
	##
	## Local to this suite on purpose: the shipped tick clock is M0d's
	## `tick_clock.gd` and is not this unit's to write.
	func estimated_tick() -> int:
		var elapsed := Time.get_ticks_msec() - int(welcome["at_msec"])
		@warning_ignore("integer_division")
		return int(welcome["tick"]) + elapsed / int(welcome["tick_ms"])

	## Every path this peer heard about a given player, oldest first.
	func paths_for(id: int) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for path in paths:
			if int(path["id"]) == id:
				out.append(path)
		return out


const Assertions := preload("res://tests/assertions.gd")

var _assertions := Assertions.new()
var _finished := false
var _peers: Array[Peer] = []
## The peer that abandoned its socket, if the live half got that far. Excluded
## from the polite close below: closing it would be the logout this suite just
## proved it did not send.
var _abandoned: Peer = null
var _restore_max_fps := 0
## Reported at the end so the margin against the runner's watchdog is visible
## rather than inferred from the run having not tripped it.
var _frames := 0


## Suite contract, polled by `run_tests.gd`. This suite reports its result and
## does not quit; the runner owns the exit code.
func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _process(_delta: float) -> void:
	_frames += 1


func _ready() -> void:
	# Always runs. The decoder is entirely client-side, so a frame injected by
	# hand exercises it exactly as a frame off the socket does, and this half of
	# the suite is what keeps a serverless run from asserting nothing at all.
	print("== interop: decoding ==")
	_test_decoding_without_a_server()

	var url := OS.get_environment(URL_ENV)
	if url.is_empty():
		# Loud, greppable, and checked for by scripts/interop_test.ps1. A skip
		# that nothing checks is a suite that quietly stopped running.
		print("INTEROP SKIPPED: %s is unset; run scripts/interop_test.ps1 to exercise it" % URL_ENV)
		_finished = true
		return

	print("== interop: live against %s ==" % url)
	_restore_max_fps = Engine.max_fps
	Engine.max_fps = MAX_FPS

	await _run(url)

	Engine.max_fps = _restore_max_fps
	for peer in _peers:
		if peer == _abandoned:
			continue
		peer.net.close()
	print(
		"INTEROP RAN: %d assertions, %d failed, %d frames"
		% [_assertions.assertion_count, _assertions.failures.size(), _frames]
	)
	_finished = true


## Every message the protocol defines, decoded from a hand-written frame.
##
## Needs no server, and covers the two things the live half cannot reach: the
## message shapes this server never emits (a one-element halt path, an `error`
## with no `re`), and the compatibility rules, since a conforming server sends
## nothing that would trip them.
func _test_decoding_without_a_server() -> void:
	var probe := Peer.new("D")
	_peers.append(probe)
	add_child(probe.net)

	probe.net.ingest_text_frame(
		'{"welcome":{"you":7,"tick_ms":150,"tick":142,'
		+ '"players":[{"id":7,"x":1.5,"z":-2.5},{"id":9,"x":0.0,"z":0.0}]}}'
	)
	_check(not probe.welcome.is_empty(), "welcome decodes")
	if probe.welcome.is_empty():
		return
	_check(int(probe.welcome["you"]) == 7, "welcome.you is 7")
	# The trap PROTOCOL.md names: every JSON number arrives as a float, so a
	# tick compared with == against an int is wrong unless it was converted.
	_check(
		typeof(probe.welcome["tick"]) == TYPE_INT and probe.welcome["tick"] == 142,
		"welcome.tick is the int 142, not a float (got %s)" % [probe.welcome["tick"]],
	)
	_check(
		typeof(probe.welcome["tick_ms"]) == TYPE_INT and probe.welcome["tick_ms"] == 150,
		"welcome.tick_ms is the int 150",
	)
	var ids: PackedInt64Array = probe.welcome["ids"]
	var positions: PackedVector2Array = probe.welcome["positions"]
	_check(Array(ids) == [7, 9], "welcome.players ids are [7, 9], got %s" % [ids])
	_check(positions.size() == 2, "welcome.players carries two positions")
	if positions.size() == 2:
		# The object encoding, {"id":..,"x":..,"z":..}.
		_check(_near(positions[0], Vector2(1.5, -2.5)), "welcome position unpacks x and z")
		_check(
			is_equal_approx(positions[0].y, -2.5),
			"Vector2.y carries world Z, not world Y (got %f)" % positions[0].y,
		)
	_check(probe.net.session_token() == "", "a welcome without session stores no token")
	probe.net.ingest_text_frame(
		'{"welcome":{"you":7,"session":"9f2c1ab7d0e4485fa6c3b81d27e05934",'
		+ '"tick_ms":150,"tick":142,'
		+ '"players":[{"id":7,"x":1.5,"z":-2.5}]}}'
	)
	_check(
		probe.net.session_token() == "9f2c1ab7d0e4485fa6c3b81d27e05934",
		"welcome.session is kept for the next URL",
	)
	_check(
		NetClientScript.url_with_session("ws://127.0.0.1:8080/ws", "abc")
		== "ws://127.0.0.1:8080/ws?session=abc",
		"url_with_session writes the query parameter",
	)
	_check(
		NetClientScript.url_with_session("ws://127.0.0.1:8080/ws?session=old", "")
		== "ws://127.0.0.1:8080/ws",
		"and strips it when the token is empty",
	)

	# Compatibility rule 2: a sender may add fields, including M2's seq.
	probe.net.ingest_text_frame('{"spawn":{"id":9,"x":3.0,"z":4.0,"seq":5,"colour":"red"}}')
	_check(probe.spawns.size() == 1, "spawn decodes past unknown fields in a known body")
	if probe.spawns.size() == 1:
		_check(int(probe.spawns[0]["id"]) == 9, "spawn.id is 9")
		_check(
			_near(probe.spawns[0]["position"], Vector2(3.0, 4.0)), "spawn position unpacks to (3, 4)"
		)

	probe.net.ingest_text_frame('{"despawn":{"id":9}}')
	_check(probe.despawns == [9], "despawn decodes to [9], got %s" % [probe.despawns])

	# The array encoding, [[x, z], ...]. Deliberately different from spawn's,
	# and the second place a client gets coordinates subtly wrong.
	probe.net.ingest_text_frame(
		'{"path":{"id":7,"start_tick":143,"points":[[1.5,-2.5],[10.0,20.0]],"speed":3.0}}'
	)
	_check(probe.paths.size() == 1, "path decodes")
	if probe.paths.size() == 1:
		var path: Dictionary = probe.paths[0]
		_check(
			typeof(path["start_tick"]) == TYPE_INT and path["start_tick"] == 143,
			"path.start_tick is the int 143, not a float",
		)
		var points: PackedVector2Array = path["points"]
		_check(points.size() == 2, "path.points has two points")
		if points.size() == 2:
			_check(_near(points[0], Vector2(1.5, -2.5)), "path.points[0] unpacks from [x, z]")
			_check(_near(points[1], Vector2(10.0, 20.0)), "path.points[1] unpacks from [x, z]")
		_check(is_equal_approx(float(path["speed"]), 3.0), "path.speed is 3.0")

	# One point means "halt here", and is the whole of "stop walking". This
	# server only emits it for a degenerate click mid-walk, which the live half
	# does not provoke.
	probe.net.ingest_text_frame('{"path":{"id":7,"start_tick":144,"points":[[1.5,-2.5]],"speed":3.0}}')
	_check(probe.paths.size() == 2, "a one-element halt path is accepted")
	if probe.paths.size() == 2:
		_check(
			(probe.paths[1]["points"] as PackedVector2Array).size() == 1,
			"the halt path keeps its single point",
		)

	probe.net.ingest_text_frame('{"error":{"re":"move_to","msg":"out of bounds"}}')
	_check(probe.errors.size() == 1, "error decodes")
	if probe.errors.size() == 1:
		_check(String(probe.errors[0]["re"]) == "move_to", "error.re is carried through")

	# "re" is absent, not null, when the frame could not be attributed.
	probe.net.ingest_text_frame('{"error":{"msg":"text frames only"}}')
	_check(probe.errors.size() == 2, "an error with no re still decodes")
	if probe.errors.size() == 2:
		_check(
			String(probe.errors[1]["re"]) == "",
			'a missing error.re reads as "", got "%s"' % String(probe.errors[1]["re"]),
		)

	# Compatibility rule 1: unknown top-level key, logged loudly and ignored.
	# The key is invented and has to be: rule 1 carries a client past a message
	# that does not exist yet, so only a key no server will ever send can
	# demonstrate it.
	probe.net.ingest_text_frame('{"m2c_no_such_message":{"t":9001}}')
	_check(
		Array(probe.unknown_keys) == ["m2c_no_such_message"],
		'an unknown key is reported as "m2c_no_such_message", got %s' % [probe.unknown_keys],
	)

	probe.net.ingest_text_frame('{"tick":{"t":9001}}')
	_check(
		Array(probe.ticks) == [9001],
		"tick decodes to its t, got %s" % [probe.ticks],
	)
	_check(
		typeof(probe.ticks[0]) == TYPE_INT,
		"and t is an int, not the float JSON hands back (%d)" % typeof(probe.ticks[0]),
	)
	_check(
		Array(probe.unknown_keys) == ["m2c_no_such_message"],
		"and tick is no longer an unknown key, got %s" % [probe.unknown_keys],
	)

	# Compatibility rule 3, plus the frames a parser gives back as null or as a
	# non-object. None of them may reach a signal.
	var before := _signal_tally(probe)
	probe.net.ingest_text_frame("{}")
	probe.net.ingest_text_frame('{"spawn":{"id":1,"x":0,"z":0},"despawn":{"id":1}}')
	probe.net.ingest_text_frame("not json at all")
	probe.net.ingest_text_frame('["spawn"]')
	probe.net.ingest_text_frame('{"spawn":42}')
	probe.net.ingest_text_frame('{"path":{"id":7,"start_tick":1,"points":[],"speed":3.0}}')
	probe.net.ingest_text_frame('{"spawn":{"id":1,"x":0}}')
	probe.net.ingest_text_frame('{"tick":{}}')
	probe.net.ingest_text_frame('{"tick":{"t":"x"}}')
	_check(
		_signal_tally(probe) == before,
		"nine malformed frames emit nothing (%s then %s)" % [before, _signal_tally(probe)],
	)


## Everything the probe has heard, as one comparable value.
func _signal_tally(peer: Peer) -> Array:
	return [
		peer.welcome.size(),
		peer.spawns.size(),
		peer.despawns.size(),
		peer.paths.size(),
		peer.errors.size(),
		peer.unknown_keys.size(),
		peer.ticks.size(),
	]


func _run(url: String) -> void:
	var a := await _join(url, "A")
	if a == null:
		return
	_test_welcome_is_first_and_complete(a)

	_test_unknown_and_malformed_frames_do_not_kill_the_client(a)

	if not await _test_move_to_inside_bounds_returns_a_path(a):
		return
	if not await _test_duplicate_seq_yields_one_path(a):
		return
	if not await _test_move_to_outside_bounds_returns_an_error(a):
		return
	if not await _test_pickup_and_drop_are_sequenced(a):
		return

	# Let A's first walk finish so the next path's origin is a known point
	# rather than an interpolated one.
	await _wait_msec(ARRIVAL_WAIT_MSEC)

	var b := await _join(url, "B")
	if b == null:
		return
	if not await _test_second_client_sees_the_world(a, b):
		return
	if not await _test_second_client_sees_the_first_walk(a, b):
		return

	await _wait_msec(MIDWALK_WAIT_MSEC)
	var c := await _join(url, "C")
	if c == null:
		return
	_test_late_joiner_gets_a_re_anchored_path(a, c)

	await _test_leaving_client_produces_a_despawn(a, b, c)

	await _test_an_abandoned_socket_is_not_a_logout(url, a, b)
	await _test_stale_token_is_a_fresh_join(url)


## `welcome` is the first frame on every connection, and describes a world
## containing only this client, at the spawn point.
func _test_welcome_is_first_and_complete(a: Peer) -> void:
	print("== welcome ==")
	_check(int(a.welcome["you"]) == 1, "welcome.you is 1 for the first connection")
	var session_len := str(a.welcome["session"]).length()
	_check(
		session_len == 32,
		"welcome.session is 32 hex characters, got length %d" % session_len,
	)
	_check(
		int(a.welcome["tick_ms"]) == EXPECTED_TICK_MS,
		"welcome.tick_ms is %d, got %d" % [EXPECTED_TICK_MS, int(a.welcome["tick_ms"])],
	)
	# The tick counter starts at 0 at process start and never resets, so a fresh
	# server's first welcome is a small non-negative number, not a timestamp.
	_check(
		int(a.welcome["tick"]) >= 0,
		"welcome.tick is a non-negative counter, got %d" % int(a.welcome["tick"]),
	)

	var ids: PackedInt64Array = a.welcome["ids"]
	var positions: PackedVector2Array = a.welcome["positions"]
	_check(ids.size() == 1, "welcome.players lists one player, got %d" % ids.size())
	_check(
		positions.size() == ids.size(),
		"welcome.players positions and ids are the same length (%d vs %d)"
		% [positions.size(), ids.size()],
	)
	if ids.size() == 1:
		_check(ids[0] == int(a.welcome["you"]), "welcome.players includes the client itself")
		_check(
			positions[0].is_equal_approx(SPAWN_POSITION),
			"the client spawns at %v, got %v" % [SPAWN_POSITION, positions[0]],
		)
	_check(a.paths.is_empty(), "no path replay for a world where nobody is walking")
	_check(a.errors.is_empty(), "a clean connection produces no error")


## Compatibility rule 1: an unknown top-level key is logged loudly and ignored,
## and the connection survives. Rule 3: a frame with zero or two keys is
## malformed and is never interpreted.
##
## The frames are injected rather than provoked, because this server cannot be
## made to send any of them. Everything after this point is what proves the
## client is still alive.
func _test_unknown_and_malformed_frames_do_not_kill_the_client(a: Peer) -> void:
	print("== unknown and malformed frames ==")
	var errors_before := a.errors.size()

	# `unknown_keys` accumulates for the whole session, so every assertion below
	# is a delta. What is already in it depends on everything this server said
	# before this function ran, and that set grows with the protocol: an M1
	# `inventory` arriving at a client that predates it is compatibility rule 1
	# working, not a failure. An assertion on the total would have to be
	# rewritten by every message the protocol ever gains.
	#
	# The unrelated key injected first is not decoration. It makes the
	# accumulator non-empty here without needing a server that sends a second
	# unknown key, so the delta below is measured rather than assumed.
	var unrelated_before := a.unknown_keys.size()
	a.net.ingest_text_frame('{"m1h_unrelated_key":{"why":"a second unknown key, from nowhere"}}')
	_check(
		a.unknown_keys.size() == unrelated_before + 1
		and a.unknown_keys[-1] == "m1h_unrelated_key",
		"an unrelated unknown key accumulates ahead of the one under test, got %s"
		% [a.unknown_keys],
	)

	var unknown_before := a.unknown_keys.size()
	# A message no server will ever send, which is the only kind that can
	# demonstrate rule 1.
	a.net.ingest_text_frame('{"m2c_no_such_message":{"t":9001}}')
	_check(
		(
			a.unknown_keys.size() == unknown_before + 1
			and a.unknown_keys[-1] == "m2c_no_such_message"
		),
		'this frame adds exactly one unknown key, named "m2c_no_such_message", got %s'
		% [a.unknown_keys],
	)
	_check(a.net.is_open(), "an unknown message leaves the connection open")

	var ticks_before := a.ticks.size()
	var unknown_before_tick := a.unknown_keys.size()
	a.net.ingest_text_frame('{"tick":{"t":9001}}')
	_check(
		a.ticks.size() == ticks_before + 1 and a.ticks[-1] == 9001,
		"a tick decodes to its t against a live connection, got %s" % [a.ticks],
	)
	_check(
		a.unknown_keys.size() == unknown_before_tick,
		"and adds no unknown key (%d added)" % (a.unknown_keys.size() - unknown_before_tick),
	)

	var unknown_before_malformed := a.unknown_keys.size()
	a.net.ingest_text_frame("{}")
	a.net.ingest_text_frame('{"welcome":{},"path":{}}')
	a.net.ingest_text_frame("not json at all")
	a.net.ingest_text_frame('["welcome"]')
	_check(a.net.is_open(), "a malformed frame leaves the connection open")
	_check(
		a.unknown_keys.size() == unknown_before_malformed,
		"a malformed frame is not mistaken for an unknown message (%d added)"
		% (a.unknown_keys.size() - unknown_before_malformed),
	)
	_check(
		a.errors.size() == errors_before,
		"a malformed frame from the server is not reported as a server error",
	)
	_check(a.welcome.has("you"), "the earlier welcome survived the malformed frames")


## A legal click produces one path, addressed to the mover, starting where the
## mover is and ending where it clicked.
func _test_move_to_inside_bounds_returns_a_path(a: Peer) -> bool:
	print("== move_to inside bounds ==")
	var you := int(a.welcome["you"])
	var sent_at_tick := a.estimated_tick()
	_check(a.net.send_move_to(FIRST_DESTINATION.x, FIRST_DESTINATION.y) == OK, "move_to sent")
	if not await _wait_until(func() -> bool: return not a.paths.is_empty(), "A's own path"):
		return false

	_check(a.paths.size() == 1, "one move_to produces one path, got %d" % a.paths.size())
	var path: Dictionary = a.paths[0]
	_check(int(path["id"]) == you, "the path is addressed to the mover (%d)" % int(path["id"]))

	var start_tick := int(path["start_tick"])
	_check(
		start_tick >= int(a.welcome["tick"]),
		"path.start_tick (%d) is at or after welcome.tick (%d)"
		% [start_tick, int(a.welcome["tick"])],
	)
	# The client's estimate lags the server by about one-way latency, so the
	# server's tick may be one ahead of what the client believed when it sent.
	_check(
		start_tick <= a.estimated_tick() + 1,
		"path.start_tick (%d) is not in the client's future beyond a tick of lag (estimate %d)"
		% [start_tick, a.estimated_tick()],
	)
	_check(
		start_tick >= sent_at_tick,
		"path.start_tick (%d) is at or after the tick the intent was sent (%d)"
		% [start_tick, sent_at_tick],
	)

	var points: PackedVector2Array = path["points"]
	# Two points today because M0 stubs pathing to a straight line. Asserted as
	# a lower bound so that a real navmesh, which is allowed to add corners,
	# does not fail a protocol test.
	_check(points.size() >= 2, "path.points has at least two points, got %d" % points.size())
	if points.size() >= 2:
		_check(
			points[0].is_equal_approx(SPAWN_POSITION),
			"path.points[0] is the mover's position at start_tick %v, got %v"
			% [SPAWN_POSITION, points[0]],
		)
		_check(
			_near(points[points.size() - 1], FIRST_DESTINATION),
			"the path ends at the clicked point %v, got %v"
			% [FIRST_DESTINATION, points[points.size() - 1]],
		)
	_check(
		is_equal_approx(float(path["speed"]), EXPECTED_SPEED),
		"path.speed is %f, got %f" % [EXPECTED_SPEED, float(path["speed"])],
	)
	return true


## The same `move_to` under the seq the first walk already spent is a duplicate.
## The server applies it once and answers the retry with nothing.
func _test_duplicate_seq_yields_one_path(a: Peer) -> bool:
	print("== duplicate seq is ignored ==")
	var you := int(a.welcome["you"])
	var paths_before := a.paths.size()
	var errors_before := a.errors.size()
	_check(
		a.net.send_move_to(FIRST_DESTINATION.x, FIRST_DESTINATION.y, 1) == OK,
		"the first walk's seq is sent again",
	)
	print("INTEROP DUPLICATE: player %d seq 1" % you)
	await _wait_msec(ABANDON_SETTLE_MSEC)
	_check(
		a.paths.size() == paths_before,
		"the same seq yields exactly one path, got %d (was %d)" % [a.paths.size(), paths_before],
	)
	_check(
		a.errors.size() == errors_before,
		"a duplicate is unanswered, not an error (%d before, %d after)"
		% [errors_before, a.errors.size()],
	)
	return true


## A pickup and a drop leave the client with the next numbers spent, so the
## event log can name those intents by seq. This world has no seed item, so both
## bodies are refused. The numbers are still consumed.
func _test_pickup_and_drop_are_sequenced(a: Peer) -> bool:
	print("== sequenced pickup and drop ==")
	var errors_before := a.errors.size()
	var paths_before := a.paths.size()
	_check(a.net.send_pickup(1) == OK, "pickup sent")
	if not await _wait_until(
		func() -> bool: return a.errors.size() > errors_before, "a pickup refusal"
	):
		return false
	_check(
		String(a.errors[a.errors.size() - 1]["re"]) == "pickup",
		'the pickup refusal names pickup, got "%s"' % String(a.errors[a.errors.size() - 1]["re"]),
	)
	_check(a.net.send_drop(0) == OK, "drop sent")
	if not await _wait_until(
		func() -> bool: return a.errors.size() > errors_before + 1, "a drop refusal"
	):
		return false
	_check(
		String(a.errors[a.errors.size() - 1]["re"]) == "drop",
		'the drop refusal names drop, got "%s"' % String(a.errors[a.errors.size() - 1]["re"]),
	)
	_check(
		a.paths.size() == paths_before,
		"a refused pickup and drop assign no path",
	)
	return true


## A click outside the world is rejected, not clamped and not snapped, and the
## rejection reaches the client that sent it.
##
## This is the failure channel. Everything else in this suite depends on it
## working, because it is how a refused intent stops looking like a dropped
## frame.
func _test_move_to_outside_bounds_returns_an_error(a: Peer) -> bool:
	print("== move_to outside bounds ==")
	_check(
		absf(OUT_OF_BOUNDS.x) > WORLD_HALF_EXTENT,
		"the test destination is genuinely outside the world",
	)
	var paths_before := a.paths.size()
	_check(a.net.send_move_to(OUT_OF_BOUNDS.x, OUT_OF_BOUNDS.y) == OK, "out-of-bounds move_to sent")
	if not await _wait_until(func() -> bool: return not a.errors.is_empty(), "an error reply"):
		return false

	_check(a.errors.size() == 1, "one rejected intent produces one error, got %d" % a.errors.size())
	var failure: Dictionary = a.errors[0]
	_check(
		String(failure["re"]) == "move_to",
		'error.re names the rejected message, got "%s"' % String(failure["re"]),
	)
	# msg is for a human reading a log, so it is asserted to exist and nothing
	# is branched on its text.
	_check(not String(failure["msg"]).is_empty(), "error.msg is non-empty")
	_check(a.net.is_open(), "a rejected intent does not close the connection")
	_check(
		a.paths.size() == paths_before,
		"a rejected intent broadcasts no path (%d before, %d after)"
		% [paths_before, a.paths.size()],
	)
	return true


## A second client joins a world that already has somebody in it, and both ends
## learn about each other: B through `welcome`, A through `spawn`.
func _test_second_client_sees_the_world(a: Peer, b: Peer) -> bool:
	print("== second client joins ==")
	var a_id := int(a.welcome["you"])
	var b_id := int(b.welcome["you"])
	_check(b_id == a_id + 1, "ids are assigned sequentially (%d then %d)" % [a_id, b_id])

	var ids: PackedInt64Array = b.welcome["ids"]
	var positions: PackedVector2Array = b.welcome["positions"]
	_check(ids.size() == 2, "B's welcome lists both players, got %d" % ids.size())
	var a_index := Array(ids).find(a_id)
	_check(a_index != -1, "B's welcome includes A (%d) in %s" % [a_id, ids])
	if a_index != -1:
		# A walked to FIRST_DESTINATION over real ticks before B connected, so
		# this is also the proof that the server's tick loop moved the player
		# rather than only answering intents.
		_check(
			_near(positions[a_index], FIRST_DESTINATION),
			"B's welcome puts A at the point A walked to %v, got %v"
			% [FIRST_DESTINATION, positions[a_index]],
		)
	var b_index := Array(ids).find(b_id)
	if b_index != -1:
		_check(
			positions[b_index].is_equal_approx(SPAWN_POSITION),
			"B's welcome puts B at the spawn point %v, got %v"
			% [SPAWN_POSITION, positions[b_index]],
		)
	_check(
		b.paths.is_empty(), "no path replay for A, who has halted (got %d)" % b.paths.size()
	)

	if not await _wait_until(func() -> bool: return not a.spawns.is_empty(), "A's spawn for B"):
		return false
	_check(a.spawns.size() == 1, "one join produces one spawn, got %d" % a.spawns.size())
	var spawn: Dictionary = a.spawns[0]
	_check(int(spawn["id"]) == b_id, "the spawn names B (%d), got %d" % [b_id, int(spawn["id"])])
	_check(
		(spawn["position"] as Vector2).is_equal_approx(SPAWN_POSITION),
		"the spawn puts B at %v, got %v" % [SPAWN_POSITION, spawn["position"]],
	)
	_check(b.spawns.is_empty(), "the joining client gets no spawn for itself")
	return true


## The M0 assertion at the interop level: one client walks and the other one
## finds out, over a real socket, without asking.
func _test_second_client_sees_the_first_walk(a: Peer, b: Peer) -> bool:
	print("== the other client sees the walk ==")
	var a_id := int(a.welcome["you"])
	_check(a.net.send_move_to(SECOND_DESTINATION.x, SECOND_DESTINATION.y) == OK, "A's move_to sent")
	if not await _wait_until(func() -> bool: return not b.paths.is_empty(), "B's copy of A's path"):
		return false

	_check(b.paths.size() == 1, "one walk produces one path on B, got %d" % b.paths.size())
	var path: Dictionary = b.paths[0]
	_check(int(path["id"]) == a_id, "B's path is A's (%d), got %d" % [a_id, int(path["id"])])
	var points: PackedVector2Array = path["points"]
	_check(points.size() >= 2, "B's path has at least two points, got %d" % points.size())
	if points.size() >= 2:
		_check(
			_near(points[0], FIRST_DESTINATION),
			"B's path starts where A actually stands %v, got %v"
			% [FIRST_DESTINATION, points[0]],
		)
		_check(
			_near(points[points.size() - 1], SECOND_DESTINATION),
			"B's path ends where A clicked %v, got %v"
			% [SECOND_DESTINATION, points[points.size() - 1]],
		)
	_check(
		is_equal_approx(float(path["speed"]), EXPECTED_SPEED),
		"B's path carries the same speed %f, got %f" % [EXPECTED_SPEED, float(path["speed"])],
	)
	_check(
		a.paths_for(a_id).size() == 2, "the mover gets its own path too, got %d" % a.paths.size()
	)
	return true


## A client joining mid-walk learns the walk through an ordinary `path`, and
## that path is re-anchored to now rather than resent verbatim.
##
## The clause with no other coverage anywhere: a verbatim resend would
## contradict the position the same `welcome` just reported.
func _test_late_joiner_gets_a_re_anchored_path(a: Peer, c: Peer) -> void:
	print("== late joiner gets a re-anchored path ==")
	var a_id := int(a.welcome["you"])
	var replays := c.paths_for(a_id)
	_check(replays.size() == 1, "C is told about A's walk exactly once, got %d" % replays.size())
	if replays.is_empty():
		return

	var path: Dictionary = replays[0]
	_check(
		int(path["start_tick"]) == int(c.welcome["tick"]),
		"the replay is anchored to the welcome's tick %d, got %d"
		% [int(c.welcome["tick"]), int(path["start_tick"])],
	)

	var points: PackedVector2Array = path["points"]
	_check(points.size() >= 2, "the replayed path still has an endpoint, got %d" % points.size())
	if points.size() < 2:
		return
	_check(
		_near(points[points.size() - 1], SECOND_DESTINATION),
		"the replay keeps A's destination %v, got %v"
		% [SECOND_DESTINATION, points[points.size() - 1]],
	)

	var travelled := _progress_along(FIRST_DESTINATION, SECOND_DESTINATION, points[0])
	_check(
		travelled > 0.0 and travelled < 1.0,
		"the replay starts partway along A's walk, not at its origin (t = %f)" % travelled,
	)
	_check(
		_distance_to_segment(FIRST_DESTINATION, SECOND_DESTINATION, points[0]) < POSITION_EPSILON,
		"the replay starts on A's polyline, got %v" % points[0],
	)

	# welcome.players and the replayed path must agree about where A is; a
	# verbatim resend is exactly the case where they would not.
	var ids: PackedInt64Array = c.welcome["ids"]
	var index := Array(ids).find(a_id)
	_check(index != -1, "C's welcome lists A")
	if index != -1:
		var listed: Vector2 = (c.welcome["positions"] as PackedVector2Array)[index]
		_check(
			_near(listed, points[0]),
			"welcome.players and the replayed path agree about A (%v vs %v)"
			% [listed, points[0]],
		)


## A client leaving produces one `despawn` for everyone else and none for itself.
func _test_leaving_client_produces_a_despawn(a: Peer, b: Peer, c: Peer) -> void:
	print("== leaving ==")
	var c_id := int(c.welcome["you"])
	c.net.close()
	if not await _wait_until(
		func() -> bool: return not a.despawns.is_empty() and not b.despawns.is_empty(),
		"a despawn for the leaver",
	):
		return
	_check(a.despawns == [c_id], "A is told C (%d) left, got %s" % [c_id, a.despawns])
	_check(b.despawns == [c_id], "B is told C (%d) left, got %s" % [c_id, b.despawns])
	_check(c.despawns.is_empty(), "the leaver gets no despawn for itself")


## A client that drops its transport without a close frame dies as `peer_gone`,
## not as `closed`. **M2c.**
##
## [b]The reason itself is not asserted here and cannot be.[/b] Only the server's
## own record says why a connection ended, so this stages the death, prints the
## id to look it up by, and leaves the verdict to the `client_disconnected` line
## in the transcript's `marqued event log`. Every other client in this suite
## closes cleanly, so that id's line is the only one that may say `peer_gone`.
##
## What is asserted is that nothing client-visible happens: a `peer_gone` player
## is suspended rather than removed, so no `despawn` reaches the survivors.
func _test_an_abandoned_socket_is_not_a_logout(url: String, a: Peer, b: Peer) -> void:
	print("== an abandoned socket is not a logout ==")
	var x := await _join(url, "X")
	if x == null:
		return
	var x_id := int(x.welcome["you"])
	_abandoned = x

	var a_despawns_before := a.despawns.size()
	var b_despawns_before := b.despawns.size()

	# Greppable, and the only way to tie the event log's line to this client:
	# ids are assigned per connection and nothing else in the transcript says
	# which one was abandoned.
	print("INTEROP ABANDONED: player %d dropped its socket without a close frame" % x_id)
	x.net.abandon()

	_check(not x.net.is_open(), "the abandoned client's socket is not open")
	_check(x.closed, "abandon() reports the disconnection without waiting for a frame")
	_check(
		x.close_code == 0,
		"and reports no close code, because no close frame was sent (got %d)" % x.close_code,
	)

	# A bounded wait rather than a predicate: what is asserted is that nothing
	# arrives, so there is no event to wait for.
	await _wait_msec(ABANDON_SETTLE_MSEC)
	_check(
		a.despawns.size() == a_despawns_before and b.despawns.size() == b_despawns_before,
		(
			"no despawn for the abandoned player %d: peer_gone suspends, it does not"
			+ " remove (A %s, B %s)"
		) % [x_id, a.despawns, b.despawns],
	)
	_check(
		a.net.is_open() and b.net.is_open(),
		"and the survivors' own connections are untouched",
	)

	var token := x.net.session_token()
	_check(token != "", "the abandoned client holds a session token")
	var inventories_before := x.inventories.size()
	var b_spawns_for_x := 0
	for spawn in b.spawns:
		if int(spawn["id"]) == x_id:
			b_spawns_for_x += 1

	x.reset_for_reconnect()
	var status := x.net.connect_to_server(NetClientScript.url_with_session(url, token))
	_check(status == OK, "X starts reconnecting with its token (status %d)" % status)
	if not await _wait_until(
		func() -> bool: return not x.welcome.is_empty(), "X's second welcome"
	):
		return
	_check(
		int(x.welcome["you"]) == x_id,
		"X's second welcome.you equals the first (%d)" % x_id,
	)
	var resumed_ids: PackedInt64Array = x.welcome["ids"]
	_check(
		Array(resumed_ids).has(int(a.welcome["you"]))
		and Array(resumed_ids).has(int(b.welcome["you"])),
		"X's second welcome lists A and B, got %s" % [resumed_ids],
	)
	var b_spawns_after := 0
	for spawn in b.spawns:
		if int(spawn["id"]) == x_id:
			b_spawns_after += 1
	_check(
		b_spawns_after == b_spawns_for_x,
		"B never gets a spawn for X's resume (still %d)" % b_spawns_after,
	)
	if await _wait_until(
		func() -> bool: return x.inventories.size() > inventories_before,
		"X's inventory to follow the second welcome",
	):
		_check(
			x.inventories.size() > inventories_before,
			"inventory followed the resume, %d restatement(s)" % x.inventories.size(),
		)
	_abandoned = null
	print("INTEROP RESUMED: player %d came back as itself" % x_id)


func _test_stale_token_is_a_fresh_join(url: String) -> void:
	print("== clean close then stale token ==")
	var s := await _join(url, "S")
	if s == null:
		return
	var old_you := int(s.welcome["you"])
	var token := s.net.session_token()
	_check(token != "", "S holds a session token")
	s.net.close()
	if not await _wait_until(func() -> bool: return s.closed, "S to close"):
		return

	s.reset_for_reconnect()
	var status := s.net.connect_to_server(NetClientScript.url_with_session(url, token))
	_check(status == OK, "S starts reconnecting with the stale token (status %d)" % status)
	if not await _wait_until(
		func() -> bool: return not s.welcome.is_empty(), "S's fresh welcome"
	):
		return
	_check(
		int(s.welcome["you"]) != old_you,
		"stale token is a new own_id() (%d -> %d)" % [old_you, int(s.welcome["you"])],
	)
	print(
		"INTEROP IDENTITY LOST: was %d now %d"
		% [old_you, int(s.welcome["you"])]
	)


## Connects one client and waits for its welcome. Returns null on failure,
## having already recorded it.
func _join(url: String, label: String) -> Peer:
	var peer := Peer.new(label)
	_peers.append(peer)
	add_child(peer.net)
	var status := peer.net.connect_to_server(url)
	_check(status == OK, "client %s starts connecting to %s (status %d)" % [label, url, status])
	if status != OK:
		return null
	if not await _wait_until(func() -> bool: return peer.opened, "client %s to open" % label):
		return null
	if not await _wait_until(
		func() -> bool: return not peer.welcome.is_empty(), "client %s's welcome" % label
	):
		return null
	return peer


## Waits until a predicate holds. Records a failure and returns false if it
## never does, so the caller stops rather than asserting on frames that will
## never arrive.
func _wait_until(predicate: Callable, what: String) -> bool:
	for _frame in WAIT_FRAMES:
		if predicate.call():
			return true
		await get_tree().process_frame
	if predicate.call():
		return true
	_check(false, "timed out after %d frames waiting for %s" % [WAIT_FRAMES, what])
	return false


## Burns frames for a wall-clock interval, so the client keeps polling while the
## server's tick loop does its work. Wall-clock is legitimate here: this is test
## sequencing, not game logic, and nothing derives a position from it.
func _wait_msec(duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _near(actual: Vector2, expected: Vector2) -> bool:
	return actual.distance_to(expected) < POSITION_EPSILON


## Where `point` falls along the segment from `from` to `to`, as a fraction.
## Values outside [0, 1] mean it is off the end.
func _progress_along(from: Vector2, to: Vector2, point: Vector2) -> float:
	var span := to - from
	var length_squared := span.length_squared()
	if length_squared == 0.0:
		return 0.0
	return (point - from).dot(span) / length_squared


func _distance_to_segment(from: Vector2, to: Vector2, point: Vector2) -> float:
	var t := clampf(_progress_along(from, to, point), 0.0, 1.0)
	return point.distance_to(from + (to - from) * t)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
