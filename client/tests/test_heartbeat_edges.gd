extends Node3D

## The heartbeat's effect on a session, at its edges. **M2c.** Fed frames into
## `main.tscn`, no server, same shape as [code]test_heartbeat.gd[/code].
##
## Written by the unit's verifier as an adversarial probe and adopted here
## unchanged in what it asserts. Three of these assertions were red when it ran
## and are the reason two rules in `PROTOCOL.md` are now written down: a
## negative `t` must not be reported as a correction, and a `tick` arriving
## after the socket died must not reopen the liveness window.
##
## [b]It is the only place that measures what a correction costs.[/b] Every
## mid-walk body derives its position from the clock, so a re-anchor moves the
## world: [method _test_re_anchor_moves_a_walker] holds a `+10` correction to
## the 1.5 units it is worth at 150 ms and 1.0 u/s, and holds a backward one to
## the clamp-at-zero rule rather than to a rewind.
##
## Three clients, because several of these are about a session's state
## surviving something, and reusing one would let an earlier test's leftovers
## decide a later test's result.

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const Assertions := preload("res://tests/assertions.gd")

const TICK_MS := 150

## Frame cap held for this suite's duration, for the reason
## [code]test_heartbeat.gd[/code] gives: headless Godot runs uncapped, so a
## wall-clock wait costs a machine-dependent number of the runner's watchdog
## frames unless one is pinned. Restored when the suite ends.
const MAX_FPS := 20


class Client:
	extends RefCounted

	const MainScene := preload("res://scenes/main.tscn")
	const SessionScript := preload("res://scripts/session.gd")
	const NetClientScript := preload("res://scripts/net_client.gd")

	var root: Node3D
	var session: SessionScript
	var net: NetClientScript
	var corrections: Array[Dictionary] = []
	var silences: Array[Dictionary] = []
	var disconnects := 0

	func _init(label: String) -> void:
		root = MainScene.instantiate() as Node3D
		root.name = "Client" + label
		session = root.get_node("Session") as SessionScript
		net = root.get_node("Session/Net") as NetClientScript
		session.clock_corrected.connect(_on_clock_corrected)
		session.server_unresponsive.connect(_on_server_unresponsive)
		net.disconnected.connect(_on_disconnected)

	func _on_clock_corrected(delta: int, at_tick: int) -> void:
		corrections.append({"delta": delta, "at_tick": at_tick})

	func _on_server_unresponsive(window: int) -> void:
		silences.append({"at_msec": Time.get_ticks_msec(), "window": window})

	func _on_disconnected(_code: int, _reason: String) -> void:
		disconnects += 1

	func feed(text: String) -> void:
		net.ingest_text_frame(text)

	func estimate() -> int:
		return session.tick_clock().estimated_tick()

	## [param heartbeat] is spliced in verbatim, so a caller says
	## [code]'"heartbeat_ticks":2,'[/code] or [code]""[/code] for a pre-M2d
	## server that names no field at all.
	func welcome(tick: int, heartbeat: String) -> void:
		feed(
			'{"welcome":{"you":1,"tick_ms":%d,"tick":%d,%s"players":[{"id":1,"x":0.0,"z":0.0}]}}'
			% [TICK_MS, tick, heartbeat]
		)


@onready var _clients: Node3D = $Clients

var _assertions := Assertions.new()
var _finished := false
var _restore_max_fps := 0


## Suite contract, polled by `run_tests.gd`. Reports; never quits.
func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	_restore_max_fps = Engine.max_fps
	Engine.max_fps = MAX_FPS

	var a := _build("A")
	var b := _build("B")
	var c := _build("C")

	# main.tscn's Session resolves its exported node paths in _ready, and a
	# suite that asserts before that reads nulls that look like scene bugs.
	await get_tree().process_frame
	await get_tree().process_frame

	print("== heartbeat edges: corrections that cost something, and windows that must not ==")
	_test_backward_then_forward(a)
	_test_re_anchor_moves_a_walker(a)
	_test_storm(a)
	_test_odd_t_values(a)
	_test_explicit_zero_and_second_welcome(c)
	await _test_welcome_only_silence_and_rewelcomed_window(b, c)
	await _test_tick_after_abandon(c)

	Engine.max_fps = _restore_max_fps
	print(
		"HEARTBEAT EDGES RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


## A correction in each direction, and the second delta measured against the
## re-anchored estimate rather than against the original welcome. That is what
## makes corrections composable: each one is relative to where the clock is now.
func _test_backward_then_forward(a: Client) -> void:
	a.welcome(100, '"heartbeat_ticks":2,')
	a.feed('{"tick":{"t":95}}')
	_check(a.estimate() == 95, "a backward heartbeat re-anchors to 95, got %d" % a.estimate())
	a.feed('{"tick":{"t":101}}')
	_check(a.estimate() == 101, "then a forward one re-anchors to 101, got %d" % a.estimate())

	var deltas := []
	for c in a.corrections:
		deltas.append(c["delta"])
	_check(
		deltas == [-5, 6],
		"deltas are -5 then +6 (measured against the re-anchored estimate), got %s" % [deltas],
	)
	_check(a.session.is_liveness_armed(), "and liveness stays armed")
	a.corrections.clear()


## What a correction costs. **The clock is not a number in a log; every walker
## reads its position from it.**
##
## A forward re-anchor advances a mid-walk body along its polyline in the frame
## the heartbeat lands, and a backward one past `start_tick` puts it back at
## `points[0]` rather than rewinding, because elapsed is clamped at zero
## (`PROTOCOL.md`, "Clock").
func _test_re_anchor_moves_a_walker(a: Client) -> void:
	var avatar: PlayerAvatarScript = a.session.avatar_for(1)
	if not _check(avatar != null, "the local avatar exists after welcome"):
		return

	a.feed('{"path":{"id":1,"start_tick":101,"points":[[0,0],[10,0]],"speed":1.0}}')
	avatar.update_to_tick(a.estimate())
	_check(
		absf(avatar.position.x) < 0.01,
		"at start_tick the body is at x=0, got %f" % avatar.position.x,
	)

	a.feed('{"tick":{"t":111}}')
	avatar.update_to_tick(a.estimate())
	_check(
		absf(avatar.position.x - 1.5) < 0.01,
		"a +10 tick re-anchor jumps the walk 1.5 units (10 x 150 ms x 1 u/s), got %f"
		% avatar.position.x,
	)

	a.feed('{"tick":{"t":90}}')
	avatar.update_to_tick(a.estimate())
	_check(
		absf(avatar.position.x) < 0.01,
		"a re-anchor behind start_tick clamps elapsed at zero: body back at x=0, got %f"
		% avatar.position.x,
	)
	a.feed('{"tick":{"t":101}}')
	a.corrections.clear()


## Volume, in both flavours. Five hundred corrections must each be a correction,
## and five hundred agreements must each be a silence: a receiver that batched
## or debounced either would be inventing a rule the contract does not have.
func _test_storm(a: Client) -> void:
	var start := a.estimate()
	for i in 500:
		a.feed('{"tick":{"t":%d}}' % (start + 1 + i))
	_check(
		a.estimate() == start + 500,
		"500 ahead-by-one ticks in one frame land at start+500, got %d (start %d)"
		% [a.estimate(), start],
	)
	_check(a.corrections.size() == 500, "each one is a correction, got %d" % a.corrections.size())

	var all_plus_one := true
	for c in a.corrections:
		if c["delta"] != 1:
			all_plus_one = false
	_check(all_plus_one, "every delta is +1")

	a.corrections.clear()
	var here := a.estimate()
	for i in 500:
		a.feed('{"tick":{"t":%d}}' % here)
	_check(a.corrections.is_empty(), "500 agreeing ticks correct nothing, got %d" % a.corrections.size())
	_check(a.estimate() == here, "and move nothing")
	_check(a.session.is_liveness_armed(), "liveness still armed after the storm")


## The `t` values that reach the session but must not reach the anchor.
##
## **A negative `t` is the one that mattered.** `TickClock.anchor` refuses it, so
## a session that reported the correction anyway would log a delta next to a
## clock that never moved — a correction log that cannot be trusted about the
## only thing it exists to say.
func _test_odd_t_values(a: Client) -> void:
	var before := a.estimate()
	a.corrections.clear()

	a.feed('{"tick":{"t":-5}}')
	_check(
		a.estimate() == before,
		"a negative t does not move the clock (TickClock refuses it), estimate %d -> %d"
		% [before, a.estimate()],
	)
	_check(
		a.corrections.is_empty(),
		"and a negative t reports no correction (the clock did not move), got %s" % [a.corrections],
	)

	a.corrections.clear()
	a.feed('{"tick":{"t":%d.7}}' % (before + 3))
	_check(
		a.estimate() == before + 3,
		"a fractional t truncates: %d.7 anchors at %d, got %d"
		% [before + 3, before + 3, a.estimate()],
	)
	_check(a.disconnects == 0, "none of it ends the session")
	a.corrections.clear()


## A `welcome` is a full restatement, so each one replaces the liveness rule the
## last one stated. Arming, disarming and re-arming all have to work on a
## session that is already joined.
func _test_explicit_zero_and_second_welcome(c: Client) -> void:
	c.welcome(200, '"heartbeat_ticks":0,')
	_check(
		not c.session.is_liveness_armed(),
		"an explicit heartbeat_ticks 0 arms nothing at the session",
	)

	c.welcome(201, '"heartbeat_ticks":2,')
	_check(c.session.is_liveness_armed(), "a second welcome (same you) with heartbeat_ticks arms")
	_check(c.estimate() == 201, "and re-anchors to its tick, got %d" % c.estimate())

	c.welcome(202, "")
	_check(not c.session.is_liveness_armed(), "a third welcome without the field disarms")
	_check(c.session.has_joined() and c.session.own_id() == 1, "and the session is still joined as 1")


## Two windows of different lengths, opened by `welcome` alone and waited out
## together. B's is the server that promised heartbeats and sent none; C's is
## the shorter window a re-welcome installed, which proves the timer is rebuilt
## from the new `heartbeat_ticks` rather than kept from the old one.
func _test_welcome_only_silence_and_rewelcomed_window(b: Client, c: Client) -> void:
	var b_opened := Time.get_ticks_msec()
	b.welcome(300, '"heartbeat_ticks":2,')
	var c_opened := Time.get_ticks_msec()
	c.welcome(400, '"heartbeat_ticks":1,')
	await _wait_msec(1300)

	if _check(
		b.silences.size() == 1,
		"welcome alone with heartbeat_ticks=2 and no tick ever: abandoned once, got %d"
		% b.silences.size(),
	):
		var elapsed: int = int(b.silences[0]["at_msec"]) - b_opened
		_check(
			elapsed >= 900 and elapsed <= 1150,
			"measured from the welcome itself: %d ms (want 900..1150)" % elapsed,
		)
	_check(b.disconnects == 1, "B disconnected once, got %d" % b.disconnects)

	if _check(
		c.silences.size() == 1,
		"a re-welcomed client uses the new window (450 ms): abandoned once, got %d"
		% c.silences.size(),
	):
		var elapsed_c: int = int(c.silences[0]["at_msec"]) - c_opened
		_check(elapsed_c >= 450 and elapsed_c <= 700, "C fired at %d ms (want 450..700)" % elapsed_c)
		_check(
			int(c.silences[0]["window"]) == 450,
			"reporting window 450, got %d" % int(c.silences[0]["window"]),
		)
	_check(c.disconnects == 1, "C disconnected once, got %d" % c.disconnects)


## The window closes with the connection and does not reopen. Nothing on the
## wire can deliver a frame after the socket is gone, so this guards a broken
## peer and a caller feeding frames by hand — but unguarded it would report a
## second death for the first one, on a timer, forever.
func _test_tick_after_abandon(c: Client) -> void:
	_check(not c.session.is_liveness_armed(), "after abandoning, C is disarmed")
	c.feed('{"tick":{"t":%d}}' % (c.estimate() + 1))
	_check(
		not c.session.is_liveness_armed(),
		"a tick fed after the socket was abandoned does not re-arm a timer on a dead connection",
	)

	await _wait_msec(700)
	_check(
		c.silences.size() == 1,
		"and server_unresponsive is not reported a second time, got %d" % c.silences.size(),
	)
	_check(c.disconnects == 1, "and disconnected stays at one, got %d" % c.disconnects)


func _build(label: String) -> Client:
	var client := Client.new(label)
	_clients.add_child(client.root)
	return client


## Burns frames for a wall-clock interval. Wall-clock is legitimate here: this
## is test sequencing, and the thing under test is itself a wall-clock deadline.
func _wait_msec(duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition
