extends Node3D

## What the heartbeat does to a session: the clock it corrects and the socket it
## abandons. **M2c.**
##
## [b]No server.[/b] Every frame here is handed to [code]main.tscn[/code]'s own
## decoder through [code]net_client.gd[/code]'s public
## [code]ingest_text_frame[/code], so this suite is green before anything sends
## a `tick` and stays green independently of what eventually does. Nothing sends
## one today; the server's half is M2d.
##
## The thing under test is [code]main.tscn[/code] itself, so every assertion is
## about the scene the game ships rather than a rig assembled for the occasion.
##
## The wire layer is the other half and lives in
## [code]test_tick_protocol.gd[/code], which needs no tree at all.
##
## [b]Two clients, and the second one is the assertion that matters.[/b]
## Liveness with `heartbeat_ticks` absent has to do nothing, because absent is
## what every server before M2d says and a client that armed a timer anyway
## would abandon every session it ever opened. "Nothing happened" is only worth
## anything if something happened next to it under the same clock, so the two
## windows are opened together and waited out once.

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
## 150 this makes the window 900 ms, which is the number the acceptance names.
const HEARTBEAT_TICKS := 2

## Frame cap held for the duration of this suite.
##
## Everything below measures silence in wall-clock milliseconds, and headless
## Godot runs uncapped at around 146 fps on this machine (NOTES.md, "Godot
## authoring traps"). Uncapped, the two-second wait below would cost close to
## three hundred frames of the runner's watchdog budget to prove one thing.
## Capped at 20 it costs forty, and a 50 ms frame still resolves a 900 ms
## deadline to well inside the slack asserted for it. Restored when the suite
## ends.
const MAX_FPS := 20

## How long the two liveness windows are watched, in milliseconds. Comfortably
## past the armed client's 900 ms window and long enough that the unarmed one
## has visibly declined to fire rather than merely not got round to it.
const WATCH_MSEC := 2000

## Slack allowed above the liveness window before the abandonment is late.
##
## The session checks its deadline once per frame, so it can never fire early
## and fires within one frame of the deadline on an idle machine. This is five
## frames at [constant MAX_FPS], which absorbs a stalled frame without being
## wide enough to hide a window computed from the wrong numbers: the nearest
## wrong answers are 450 ms and 1800 ms.
const LATE_SLACK_MSEC := 250


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
	## Monotonic milliseconds at which each `server_unresponsive` arrived, with
	## the window it reported.
	var silences: Array[Dictionary] = []
	var disconnects := 0

	func _init(client_label: String) -> void:
		label = client_label
		root = MainScene.instantiate() as Node3D
		root.name = "Client" + label
		session = root.get_node("Session") as SessionScript
		net = root.get_node("Session/Net") as NetClientScript
		session.clock_corrected.connect(_on_clock_corrected)
		session.server_unresponsive.connect(_on_server_unresponsive)
		net.disconnected.connect(_on_disconnected)

	## Hands one frame to this client's decoder as if it had arrived on the
	## socket.
	func feed(text: String) -> void:
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

	var armed := _build("Armed")
	var unarmed := _build("Unarmed")

	# main.tscn's Session resolves its exported node paths in _ready, and a
	# suite that asserts before that reads nulls that look like scene bugs.
	await get_tree().process_frame
	await get_tree().process_frame

	print("== heartbeat: the clock it corrects and the socket it abandons ==")
	_test_a_tick_before_welcome_is_ignored(armed)
	_test_a_heartbeat_re_anchors_the_clock(armed)
	_test_an_agreeing_heartbeat_changes_nothing(armed)
	_test_a_malformed_tick_is_dropped_and_the_next_frame_applies(armed)
	_test_a_heartbeat_reopens_the_liveness_window(armed)
	await _test_a_silent_server_is_abandoned_and_an_unarmed_one_is_not(armed, unarmed)

	Engine.max_fps = _restore_max_fps
	print(
		"HEARTBEAT RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


## Nothing reaches a connection before its `welcome` (`PROTOCOL.md`, "Ordering
## and the join race"), and there would be no `tick_ms` to re-anchor with if it
## did. So a `tick` here is defence against a broken peer: logged, ignored, and
## it must not leave the clock anchored to a tick nobody welcomed us at.
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


## The acceptance case: a server one tick ahead of the client's estimate.
##
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
	# The rendered line, not just the numbers. `%+d` is the part that can be
	# silently lost: without the sign every correction reads as if the client
	# were behind, and the sign is the whole diagnosis (`PROTOCOL.md`, "Clock").
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


## A heartbeat that agrees with the estimate does nothing and says nothing.
## Agreement is the ordinary case once the clock is right, so a line per
## heartbeat would bury the corrections the log exists for.
func _test_an_agreeing_heartbeat_changes_nothing(client: Client) -> void:
	client.clear()
	var before := client.session.tick_clock().estimated_tick()
	client.feed('{"tick":{"t":%d}}' % before)
	_check(
		client.corrections.is_empty(),
		"a heartbeat matching the estimate reports no correction, got %s"
		% [client.corrections],
	)
	_check(
		client.session.tick_clock().estimated_tick() == before,
		"and leaves the estimate where it was (%d)" % before,
	)


## A heartbeat whose `t` cannot be read is dropped, and the connection is kept.
## The proof that it was kept is the frame after it.
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


## The window is measured from the last tick-bearing frame, so every heartbeat
## that decodes reopens it — including one that agrees with the estimate. The
## frame is proof the server is alive whatever it says about the clock.
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

	# An agreeing heartbeat, which corrects nothing. It still has to reopen the
	# window: the frame is proof the server is alive whatever it says about the
	# clock, and a client that only reset its timer on corrections would abandon
	# a server whose clock it agrees with.
	client.clear()
	client.feed('{"tick":{"t":%d}}' % client.session.tick_clock().estimated_tick())
	_check(client.corrections.is_empty(), "an agreeing heartbeat still corrects nothing")
	_check(
		client.session.is_liveness_armed(),
		"and leaves the window armed rather than cancelling it",
	)


## The acceptance pair, waited out under one clock. **The unarmed client is the
## half that protects every session against a pre-M2d server.**
func _test_a_silent_server_is_abandoned_and_an_unarmed_one_is_not(
	armed: Client, unarmed: Client
) -> void:
	# The unarmed client's welcome names no heartbeat_ticks, which is every
	# server before M2d.
	unarmed.feed(_welcome_frame(WELCOME_TICK, -1))
	_check(
		not unarmed.session.is_liveness_armed(),
		"the unarmed client runs no liveness timer",
	)

	var window := SessionScript.LIVENESS_HEARTBEATS * HEARTBEAT_TICKS * TICK_MS
	_check(window == 900, "the armed window is 3 heartbeats of 2 ticks at 150 ms, got %d" % window)

	# The window is reopened here rather than in the test above, so that the
	# elapsed time below is measured from the frame that opened it. Reading the
	# clock a few lines later would let a millisecond of drift make a correct
	# 900 ms window look like 899.
	var opened_at := Time.get_ticks_msec()
	armed.feed('{"tick":{"t":%d}}' % armed.session.tick_clock().estimated_tick())
	await _wait_msec(WATCH_MSEC)

	if _check(
		armed.silences.size() == 1,
		"the armed client abandons its socket exactly once, got %d" % armed.silences.size(),
	):
		var silence: Dictionary = armed.silences[0]
		var elapsed: int = int(silence["at_msec"]) - opened_at
		_check(
			int(silence["window"]) == window,
			"reporting the %d ms window it waited, got %d" % [window, int(silence["window"])],
		)
		_check(
			elapsed >= window,
			"never before the window is up (%d ms elapsed, window %d)" % [elapsed, window],
		)
		_check(
			elapsed <= window + LATE_SLACK_MSEC,
			"and within a frame or so of it (%d ms elapsed, window %d)" % [elapsed, window],
		)
	_check(
		not armed.session.is_liveness_armed(),
		"the timer disarms itself rather than firing again every frame",
	)
	_check(
		not armed.net.is_open(),
		"and the socket is not open afterwards",
	)
	# The observable proof that the session called `abandon()`. Whether the
	# transport really went without a close frame is a claim about
	# [WebSocketPeer] that only a server can settle, and the live half of
	# `test_interop.gd` is where it is settled.
	_check(
		armed.disconnects == 1,
		"the abandonment is reported as a disconnection, exactly once, got %d"
		% armed.disconnects,
	)

	_check(
		unarmed.silences.is_empty(),
		"the unarmed client is untouched after %d ms, got %s" % [WATCH_MSEC, unarmed.silences],
	)
	_check(
		unarmed.disconnects == 0,
		"and its session was never ended, got %d disconnection(s)" % unarmed.disconnects,
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


## Burns frames for a wall-clock interval. Wall-clock is legitimate here: this
## is test sequencing, and the thing under test is itself a wall-clock deadline.
func _wait_msec(duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition
