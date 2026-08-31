extends Node

## Godot-to-Go interop: real `marqued`, real sockets, real frames.
##
## Everything here runs against a live server process. Nothing is stubbed and
## nothing is mocked, because the assumption this unit exists to retire is
## exactly the one a mock would assume away: that Godot's [WebSocketPeer] and
## the Go server can talk to each other at all.
##
## [b]Requires a server.[/b] The websocket URL comes from the environment
## variable named by [constant URL_ENV], and the server must be freshly started
## with no other clients attached: the suite asserts on sequentially assigned
## player ids and on a world containing only its own clients. Run the whole
## thing with
##
## [codeblock]
## powershell -ExecutionPolicy Bypass -File scripts/interop_test.ps1
## [/codeblock]
##
## which builds the server, starts it on a free port, exports the variable, runs
## the suite, and shuts the server down. With the variable unset the suite skips
## loudly and the run stays green, so the plain
## [code]--script res://tests/run_tests.gd[/code] command still works without a
## server; that script checks for the skip and fails on it.
##
## Reports through `finished` and `passed` rather than quitting the tree. See
## `run_tests.gd`.

## Names the environment variable carrying the websocket URL.
const URL_ENV := "MARQUE_WS_URL"

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
const MAX_FPS := 60

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

	## Empty until `welcome` arrives. Keys: you, tick_ms, tick, ids, positions,
	## at_msec.
	var welcome := {}
	var paths: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
	var spawns: Array[Dictionary] = []
	var despawns: Array[int] = []
	var unknown_keys := PackedStringArray()

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
		net.server_error.connect(_on_server_error)
		net.unknown_message.connect(_on_unknown_message)

	func _on_connected() -> void:
		opened = true

	func _on_disconnected(code: int, _reason: String) -> void:
		closed = true
		close_code = code

	func _on_welcomed(
		you: int,
		tick_ms: int,
		tick: int,
		player_ids: PackedInt64Array,
		player_positions: PackedVector2Array,
	) -> void:
		welcome = {
			"you": you,
			"tick_ms": tick_ms,
			"tick": tick,
			"ids": player_ids,
			"positions": player_positions,
			# The clock anchor from PROTOCOL.md, "Clock": monotonic, never a
			# frame-delta accumulation.
			"at_msec": Time.get_ticks_msec(),
		}

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


## Set once the suite is done; read by `run_tests.gd`. See its suite contract.
var finished := false
var passed := false

var _failures: Array[String] = []
var _assertions := 0
var _peers: Array[Peer] = []
var _restore_max_fps := 0
## Reported at the end so the margin against the runner's watchdog is visible
## rather than inferred from the run having not tripped it.
var _frames := 0


func _process(_delta: float) -> void:
	_frames += 1


func _ready() -> void:
	var url := OS.get_environment(URL_ENV)
	if url.is_empty():
		# Loud, greppable, and checked for by scripts/interop_test.ps1. A skip
		# that nothing checks is a suite that quietly stopped running.
		print("INTEROP SKIPPED: %s is unset; run scripts/interop_test.ps1 to exercise it" % URL_ENV)
		_finish()
		return

	print("== interop: %s ==" % url)
	_restore_max_fps = Engine.max_fps
	Engine.max_fps = MAX_FPS

	await _run(url)

	Engine.max_fps = _restore_max_fps
	for peer in _peers:
		peer.net.close()
	print(
		"INTEROP RAN: %d assertions, %d failed, %d frames"
		% [_assertions, _failures.size(), _frames]
	)
	_finish()


func _run(url: String) -> void:
	var a := await _join(url, "A")
	if a == null:
		return
	_test_welcome_is_first_and_complete(a)

	_test_unknown_and_malformed_frames_do_not_kill_the_client(a)

	if not await _test_move_to_inside_bounds_returns_a_path(a):
		return
	if not await _test_move_to_outside_bounds_returns_an_error(a):
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


## `welcome` is the first frame on every connection, and describes a world
## containing only this client, at the spawn point.
func _test_welcome_is_first_and_complete(a: Peer) -> void:
	print("== welcome ==")
	_check(int(a.welcome["you"]) == 1, "welcome.you is 1 for the first connection")
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

	# The shape M2's heartbeat will have, arriving at a client built today.
	a.net.ingest_text_frame('{"tick":{"t":9001}}')
	_check(
		a.unknown_keys.size() == 1 and a.unknown_keys[0] == "tick",
		'an unknown key is reported once as "tick", got %s' % [a.unknown_keys],
	)
	_check(a.net.is_open(), "an unknown message leaves the connection open")

	a.net.ingest_text_frame("{}")
	a.net.ingest_text_frame('{"welcome":{},"path":{}}')
	a.net.ingest_text_frame("not json at all")
	a.net.ingest_text_frame('["welcome"]')
	_check(a.net.is_open(), "a malformed frame leaves the connection open")
	_check(
		a.unknown_keys.size() == 1,
		"a malformed frame is not mistaken for an unknown message (%d unknown keys)"
		% a.unknown_keys.size(),
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
	_assertions += 1
	if condition:
		print("  ok    " + message)
		return
	_failures.append(message)
	print("  FAIL  " + message)


func _finish() -> void:
	if not _failures.is_empty():
		printerr("FAIL: interop, %d assertion(s) failed" % _failures.size())
		for failure in _failures:
			printerr("  - " + failure)
	passed = _failures.is_empty()
	finished = true
