extends Node3D

## What the heartbeat does to a session: the clock it corrects and the socket it
## abandons. **M2c.** Frames are fed to an instanced [code]main.tscn[/code]
## through [code]net_client.gd[/code]'s public [code]ingest_text_frame[/code],
## so nothing here connects to anything.
##
## The wire layer is the other half and lives in
## [code]test_tick_protocol.gd[/code], which needs no tree at all.

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const Assertions := preload("res://tests/assertions.gd")

## The clock this suite feeds, in the units the wire uses.
const TICK_MS := 150
const WELCOME_TICK := 100
## `welcome.heartbeat_ticks` for the client whose liveness is armed. With
## [constant SessionScript.LIVENESS_HEARTBEATS] at 3 and [constant TICK_MS] at
## 150 this makes the window 900 ms.
const HEARTBEAT_TICKS := 2

## Frame cap held for the duration of this suite, and restored at its end.
## Headless Godot runs uncapped at around 146 fps on this machine (NOTES.md,
## "Godot authoring traps"), and every wait below is wall-clock, so uncapped
## they would cost several hundred frames of the runner's watchdog budget.
const MAX_FPS := 10

## How long the two liveness windows are watched, in milliseconds.
const WATCH_MSEC := 2000

## Slack allowed above the liveness window before the abandonment is late. Two
## and a half frames at [constant MAX_FPS], which absorbs a stalled frame but is
## not wide enough to hide a window computed from the wrong numbers: the nearest
## wrong answers are 450 ms and 1800 ms.
const LATE_SLACK_MSEC := 250

## Ticks the free-running clock may advance across one synchronous block. One
## 150 ms boundary can fall between two reads; two cannot without the block
## having stalled, and a re-anchor moves the estimate far further than either.
const FREE_RUN_TICKS := 1


## One instanced client and everything its session reported.
class Client:
	extends RefCounted

	const MainScene := preload("res://scenes/main.tscn")
	const SessionScript := preload("res://scripts/session.gd")
	const NetClientScript := preload("res://scripts/net_client.gd")

	var label: String
	var root: Node3D
	var session: SessionScript
	var net: NetClientScript

	## One record per correction, as `{"delta": int, "at_tick": int}`.
	var corrections: Array[Dictionary] = []
	## One record per `server_unresponsive`, as
	## `{"at_msec": <monotonic>, "window": int}`.
	var silences: Array[Dictionary] = []
	var disconnects := 0
	## Frames fed to this client whose top-level key was `tick`.
	var ticks_fed := 0

	func _init(client_label: String) -> void:
		label = client_label
		root = MainScene.instantiate() as Node3D
		root.name = "Client" + label
		session = root.get_node("Session") as SessionScript
		net = root.get_node("Session/Net") as NetClientScript
		session.clock_corrected.connect(_on_clock_corrected)
		session.server_unresponsive.connect(_on_server_unresponsive)
		net.disconnected.connect(_on_disconnected)

	func feed(text: String) -> void:
		if text.begins_with('{"tick"'):
			ticks_fed += 1
		net.ingest_text_frame(text)

	func clear() -> void:
		corrections.clear()

	func _on_clock_corrected(delta: int, at_tick: int) -> void:
		corrections.append({"delta": delta, "at_tick": at_tick})

	func _on_server_unresponsive(silent_msec: int) -> void:
		silences.append({"at_msec": Time.get_ticks_msec(), "window": silent_msec})

	func _on_disconnected(_code: int, _reason: String) -> void:
		disconnects += 1


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

	var corrected := _build("Corrected")
	var silent := _build("Silent")
	var unarmed := _build("Unarmed")

	# main.tscn's Session resolves its exported node paths in _ready, and a
	# suite that asserts before that reads nulls that look like scene bugs.
	await get_tree().process_frame
	await get_tree().process_frame

	print("== heartbeat: the clock it corrects and the socket it abandons ==")
	_test_a_tick_before_welcome_is_ignored(corrected)
	_test_a_heartbeat_re_anchors_the_clock(corrected)
	_test_an_agreeing_heartbeat_changes_nothing(corrected)
	_test_a_negative_tick_is_dropped_rather_than_reported_as_a_correction(corrected)
	_test_a_malformed_tick_is_dropped_and_the_next_frame_applies(corrected)
	_test_a_heartbeat_reopens_the_liveness_window(corrected)
	await _test_a_welcome_alone_arms_the_window_and_an_unarmed_client_is_untouched(
		silent, unarmed
	)
	await _test_a_tick_after_the_socket_died_does_not_reopen_the_window(silent)

	Engine.max_fps = _restore_max_fps
	print(
		"HEARTBEAT RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_a_tick_before_welcome_is_ignored(client: Client) -> void:
	_check(
		not client.session.tick_clock().is_anchored(),
		"the clock is unanchored before welcome",
	)
	client.feed('{"tick":{"t":5}}')
	_check(
		not client.session.tick_clock().is_anchored(),
		"a tick before welcome does not anchor the clock",
	)
	_check(
		client.corrections.is_empty(),
		"and corrects nothing, got %s" % [client.corrections],
	)
	_check(not client.session.has_joined(), "and does not join the session")


## The `welcome` and the `tick` are fed in the same synchronous block, so no
## wall time passes between them and the estimate at receipt is exactly
## `WELCOME_TICK`. That is what makes `+1` the expected delta rather than a
## number that depends on how long a frame took.
func _test_a_heartbeat_re_anchors_the_clock(client: Client) -> void:
	client.feed(_welcome_frame(WELCOME_TICK, -1))
	_check(
		client.session.tick_clock().estimated_tick() == WELCOME_TICK,
		"welcome anchors the clock at %d, got %d"
		% [WELCOME_TICK, client.session.tick_clock().estimated_tick()],
	)

	client.feed('{"tick":{"t":%d}}' % (WELCOME_TICK + 1))
	_check(
		client.session.tick_clock().estimated_tick() == WELCOME_TICK + 1,
		"a heartbeat one tick ahead re-anchors immediately, estimate is %d, got %d"
		% [WELCOME_TICK + 1, client.session.tick_clock().estimated_tick()],
	)
	if not _check(
		client.corrections.size() == 1,
		"and reports exactly one correction, got %d" % client.corrections.size(),
	):
		return
	var correction: Dictionary = client.corrections[0]
	_check(
		correction["delta"] == 1,
		"the correction is +1 tick, got %d" % correction["delta"],
	)
	_check(
		correction["at_tick"] == WELCOME_TICK + 1,
		"named at the heartbeat's own tick %d, got %d"
		% [WELCOME_TICK + 1, correction["at_tick"]],
	)
	_check(
		SessionScript.correction_line(1, WELCOME_TICK + 1)
		== "session: clock corrected by +1 tick(s) at heartbeat 101",
		'the logged line reads "%s"' % SessionScript.correction_line(1, WELCOME_TICK + 1),
	)
	_check(
		SessionScript.correction_line(-2, 40)
		== "session: clock corrected by -2 tick(s) at heartbeat 40",
		'and a client running ahead reads "%s"' % SessionScript.correction_line(-2, 40),
	)


func _test_an_agreeing_heartbeat_changes_nothing(client: Client) -> void:
	client.clear()
	var before := client.session.tick_clock().estimated_tick()
	client.feed('{"tick":{"t":%d}}' % before)
	_check(
		client.corrections.is_empty(),
		"a heartbeat matching the estimate reports no correction, got %s"
		% [client.corrections],
	)
	_check_clock_free_ran(client, before, "an agreeing heartbeat")


## `TickClock.anchor` refuses a negative tick, so a session that reported the
## correction anyway would log a delta next to a clock that had not moved.
func _test_a_negative_tick_is_dropped_rather_than_reported_as_a_correction(
	client: Client
) -> void:
	client.clear()
	var before := client.session.tick_clock().estimated_tick()
	client.feed('{"tick":{"t":-1}}')
	client.feed('{"tick":{"t":-606}}')
	_check(
		client.corrections.is_empty(),
		"a negative tick reports no correction, got %s" % [client.corrections],
	)
	_check_clock_free_ran(client, before, "a negative tick")
	_check(client.disconnects == 0, "and does not end the session")


func _test_a_malformed_tick_is_dropped_and_the_next_frame_applies(client: Client) -> void:
	client.clear()
	client.feed('{"tick":{}}')
	client.feed('{"tick":{"t":"x"}}')
	_check(
		client.corrections.is_empty(),
		"a tick with no numeric t corrects nothing, got %s" % [client.corrections],
	)
	_check(client.disconnects == 0, "and does not end the session")

	client.feed('{"spawn":{"id":42,"x":3.0,"z":-4.0}}')
	var avatar: PlayerAvatarScript = client.session.avatar_for(42)
	if _check(avatar != null, "and a spawn arriving after it still applies"):
		_check(
			avatar.position.x == 3.0 and avatar.position.z == -4.0,
			"putting the body where the spawn said, got (%f, %f)"
			% [avatar.position.x, avatar.position.z],
		)


func _test_a_heartbeat_reopens_the_liveness_window(client: Client) -> void:
	_check(
		not client.session.is_liveness_armed(),
		"a welcome with no heartbeat_ticks arms no timer",
	)
	client.feed(_welcome_frame(WELCOME_TICK, HEARTBEAT_TICKS))
	_check(
		client.session.is_liveness_armed(),
		"a welcome naming heartbeat_ticks arms one",
	)

	client.clear()
	client.feed('{"tick":{"t":%d}}' % client.session.tick_clock().estimated_tick())
	_check(client.corrections.is_empty(), "an agreeing heartbeat still corrects nothing")
	_check(
		client.session.is_liveness_armed(),
		"and leaves the window armed rather than cancelling it",
	)

	# Disarmed again before this client is left alone: the tests that follow
	# spend seconds waiting, and a timer still running here would fire in them.
	client.feed(_welcome_frame(WELCOME_TICK, -1))
	_check(
		not client.session.is_liveness_armed(),
		"and a later welcome that stops promising heartbeats disarms it",
	)


## Two windows waited out under one clock: "nothing happened" to the unarmed
## client is only worth anything next to something that did happen.
##
## `silent` is a client of its own so that "no tick was ever fed" is a property
## of the client rather than of the order the tests happen to run in.
func _test_a_welcome_alone_arms_the_window_and_an_unarmed_client_is_untouched(
	silent: Client, unarmed: Client
) -> void:
	var window := SessionScript.LIVENESS_HEARTBEATS * HEARTBEAT_TICKS * TICK_MS
	_check(window == 900, "the armed window is 3 heartbeats of 2 ticks at 150 ms, got %d" % window)

	# Read immediately before the welcome that opens the window: a few lines of
	# drift would make a correct 900 ms window look like 899.
	var opened_at := Time.get_ticks_msec()
	silent.feed(_welcome_frame(WELCOME_TICK, HEARTBEAT_TICKS))
	unarmed.feed(_welcome_frame(WELCOME_TICK, -1))
	_check(
		silent.session.is_liveness_armed(),
		"a welcome alone arms the window, with no tick behind it",
	)
	_check(
		not unarmed.session.is_liveness_armed(),
		"and a welcome with no heartbeat_ticks arms nothing",
	)

	await _wait_msec(WATCH_MSEC)

	if _check(
		silent.silences.size() == 1,
		"the silent server's client abandons its socket exactly once, got %d"
		% silent.silences.size(),
	):
		var silence: Dictionary = silent.silences[0]
		var elapsed: int = int(silence["at_msec"]) - opened_at
		_check(
			silent.ticks_fed == 0,
			"having been fed no tick at all, got %d" % silent.ticks_fed,
		)
		_check(
			int(silence["window"]) == window,
			"reporting the %d ms window it waited, got %d" % [window, int(silence["window"])],
		)
		_check(
			elapsed >= window,
			"never before the window is up (%d ms after its welcome, window %d)"
			% [elapsed, window],
		)
		_check(
			elapsed <= window + LATE_SLACK_MSEC,
			"and within a frame or so of it (%d ms after its welcome, window %d)"
			% [elapsed, window],
		)
	_check(
		not silent.session.is_liveness_armed(),
		"the timer disarms itself rather than firing again every frame",
	)
	# `is_open()` is not asserted: it is false on a client that never connected,
	# so it would pass whether or not the session abandoned anything.
	_check(
		silent.disconnects == 1,
		"the abandonment is reported as a disconnection, exactly once, got %d"
		% silent.disconnects,
	)

	_check(
		unarmed.silences.is_empty(),
		"the unarmed client is untouched after %d ms, got %s" % [WATCH_MSEC, unarmed.silences],
	)
	_check(
		unarmed.disconnects == 0,
		"and its session was never ended, got %d disconnection(s)" % unarmed.disconnects,
	)


func _test_a_tick_after_the_socket_died_does_not_reopen_the_window(silent: Client) -> void:
	_check(not silent.session.is_liveness_armed(), "the abandoned client is disarmed")
	silent.feed('{"tick":{"t":%d}}' % (silent.session.tick_clock().estimated_tick() + 1))
	_check(
		not silent.session.is_liveness_armed(),
		"and a tick arriving afterwards does not arm a timer on a dead connection",
	)

	await _wait_msec(SessionScript.LIVENESS_HEARTBEATS * HEARTBEAT_TICKS * TICK_MS
		+ LATE_SLACK_MSEC)
	_check(
		silent.silences.size() == 1,
		"so no second abandonment is reported, got %d" % silent.silences.size(),
	)
	_check(
		silent.disconnects == 1,
		"and the session still ended exactly once, got %d" % silent.disconnects,
	)


## A `welcome` for one player at the origin. [param heartbeat_ticks] below zero
## omits the field, which is what a pre-M2d server sends.
func _welcome_frame(tick: int, heartbeat_ticks: int) -> String:
	var heartbeat := ""
	if heartbeat_ticks >= 0:
		heartbeat = '"heartbeat_ticks":%d,' % heartbeat_ticks
	return (
		'{"welcome":{"you":1,"tick_ms":%d,"tick":%d,%s"players":[{"id":1,"x":0.0,"z":0.0}]}}'
		% [TICK_MS, tick, heartbeat]
	)


func _build(label: String) -> Client:
	var client := Client.new(label)
	_clients.add_child(client.root)
	return client


func _wait_msec(duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


## Asserts the clock free-ran rather than being re-anchored.
##
## The estimate is a function of wall time, so two reads either side of a
## `feed()` legitimately differ by a tick when a 150 ms boundary falls between
## them. Asserting equality made both callers flaky under load, and the
## verifier's run caught it. A re-anchor is still caught: it moves the estimate
## to `t`, which for every `t` these callers send is hundreds of ticks away.
func _check_clock_free_ran(client: Client, before: int, what: String) -> void:
	var now := client.session.tick_clock().estimated_tick()
	_check(
		now >= before and now <= before + FREE_RUN_TICKS,
		"%s leaves the clock free-running, not re-anchored (%d -> %d, at most +%d)"
		% [what, before, now, FREE_RUN_TICKS],
	)


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition
