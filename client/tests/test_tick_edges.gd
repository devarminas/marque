extends RefCounted

## The `tick` wire layer at its edges, with no scene tree and no server. **M2c.**
##
## Written by the unit's verifier as an adversarial probe and adopted here
## unchanged in what it asserts. It is the companion to
## [code]test_tick_protocol.gd[/code], which covers the shapes the contract
## names; this covers the ones it does not — a fractional `t`, a negative one,
## `1e18`, a boolean, two thousand in a single call, and frames arriving after
## the socket was abandoned.
##
## [b]The decoder is stateless, and this is where that is pinned.[/b] A `tick`
## after [method abandon] still decodes, because [code]net_client.gd[/code] has
## no notion of a session being over. What does have that notion is
## [code]session.gd[/code], and [code]test_heartbeat_edges.gd[/code] holds it to
## it.
##
## Tree-free on purpose, like every other decoder suite here.

const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var ticks: Array[int] = []
	## One entry per `welcome`: the `heartbeat_ticks` it was read as.
	var welcomes: Array[int] = []
	var disconnects := 0
	var unknown := 0

	func _init() -> void:
		net = NetClientScript.new()
		net.tick_received.connect(func(t: int) -> void: ticks.append(t))
		net.welcomed.connect(_on_welcomed)
		net.disconnected.connect(func(_c: int, _r: String) -> void: disconnects += 1)
		net.unknown_message.connect(func(_k: String) -> void: unknown += 1)

	func _on_welcomed(
		_you: int,
		_tick_ms: int,
		_tick: int,
		heartbeat_ticks: int,
		_ids: PackedInt64Array,
		_positions: PackedVector2Array,
	) -> void:
		welcomes.append(heartbeat_ticks)

	func feed(text: String) -> void:
		net.ingest_text_frame(text)

	func release() -> void:
		net.free()


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions

	_test_numeric_shapes_of_t()
	_test_a_storm_decodes_in_order()
	_test_ticks_after_abandon_still_decode_and_the_session_ended_once()
	_test_a_second_welcome_re_reads_heartbeat_ticks()

	assertions.finish()


## Every numeric shape JSON can put in `t`, and the line between "numeric" and
## "not". The boolean is the interesting one: it is not a number, so it is
## dropped, and nothing here quietly converts it to 1.
func _test_numeric_shapes_of_t() -> void:
	var r := Recorder.new()

	r.feed('{"tick":{"t":100.7}}')
	_check(r.ticks == [100], "a fractional t truncates to 100, got %s" % [r.ticks])

	r.ticks.clear()
	r.feed('{"tick":{"t":-5}}')
	_check(
		r.ticks == [-5],
		"a negative t is numeric and reaches the listener as -5, got %s" % [r.ticks],
	)

	r.ticks.clear()
	r.feed('{"tick":{"t":1e18}}')
	_check(
		r.ticks == [1000000000000000000],
		"a 1e18 t survives as an int, got %s" % [r.ticks],
	)

	r.ticks.clear()
	r.feed('{"tick":{"t":true}}')
	r.feed('{"tick":{"t":false}}')
	_check(r.ticks.is_empty(), "a boolean t is not a number and is dropped, got %s" % [r.ticks])

	r.feed('{"tick":{"t":0}}')
	_check(r.ticks == [0], "t=0 is a legal tick, got %s" % [r.ticks])
	_check(r.disconnects == 0 and r.unknown == 0, "none of it closes or is unknown")
	r.release()


## Ordering under volume. A heartbeat is one frame among many, and the decoder
## must neither reorder nor coalesce them at any rate.
func _test_a_storm_decodes_in_order() -> void:
	var r := Recorder.new()
	for t in 2000:
		r.feed('{"tick":{"t":%d}}' % t)

	var ordered := r.ticks.size() == 2000
	for t in r.ticks.size():
		if r.ticks[t] != t:
			ordered = false
			break
	_check(ordered, "2000 ticks in one call decode in order, got %d" % r.ticks.size())
	r.release()


## The decoder has no notion of a session being over, and it should not: knowing
## when to stop listening is the session's job. What this pins is that
## [method abandon] is idempotent and that a `close` behind it adds nothing, so
## a session ends exactly once however many times it is ended.
func _test_ticks_after_abandon_still_decode_and_the_session_ended_once() -> void:
	var r := Recorder.new()
	r.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":10,"heartbeat_ticks":2,'
		+ '"players":[{"id":1,"x":0,"z":0}]}}'
	)
	r.net.abandon()
	r.feed('{"tick":{"t":11}}')
	r.net.abandon()
	r.net.close()
	_check(
		r.disconnects == 1,
		"disconnected once across abandon, tick, abandon, close; got %d" % r.disconnects,
	)
	_check(
		r.ticks == [11],
		"the decoder is stateless: a tick after abandon still decodes, got %s" % [r.ticks],
	)
	r.release()


## `heartbeat_ticks` is read fresh from every `welcome`, because a `welcome` is
## a full restatement rather than a patch. So a server may promise heartbeats,
## stop promising them, and promise again, and each statement replaces the last.
func _test_a_second_welcome_re_reads_heartbeat_ticks() -> void:
	var r := Recorder.new()
	var players := '"players":[{"id":1,"x":0,"z":0}]}}'
	r.feed('{"welcome":{"you":1,"tick_ms":150,"tick":10,"heartbeat_ticks":2,' + players)
	r.feed('{"welcome":{"you":1,"tick_ms":150,"tick":12,' + players)
	r.feed('{"welcome":{"you":1,"tick_ms":150,"tick":14,"heartbeat_ticks":2.9,' + players)
	r.feed('{"welcome":{"you":1,"tick_ms":150,"tick":16,"heartbeat_ticks":true,' + players)
	_check(
		r.welcomes == [2, 0, 2, 0],
		"heartbeat_ticks per welcome reads 2, absent->0, 2.9->2, true->0; got %s" % [r.welcomes],
	)
	r.release()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition
