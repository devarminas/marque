extends RefCounted

## Converts monotonic wall time into an estimated server tick.
##
## This is the one place in the client that reads a clock. Everything else takes
## a tick (NOTES.md, "Tick rate"; PROTOCOL.md, "Clock"). Nothing here knows about
## the network: the caller receives [code]welcome[/code], pulls [code]tick[/code]
## and [code]tick_ms[/code] out of it, and hands them to [method anchor].
##
## PROTOCOL.md, "Clock", is the spec:
##
##     estimated_tick = anchor_tick + floor((monotonic_now - anchor_time) / tick_ms)
##
## [b]It never accumulates frame deltas.[/b] A minimized or stalled window stops
## producing frames, and a frame-delta clock then falls permanently behind with
## nothing to correct it. Every estimate is recomputed from the anchor against a
## monotonic time source, so a stall of any length costs nothing to recover from.
## That is why this class has no [method Node._process] and is not a [Node].
##
## Typed by [code]preload[/code] rather than by a [code]class_name[/code], per
## NOTES.md, "Godot authoring traps":
##
## [codeblock]
## const TickClock := preload("res://scripts/tick_clock.gd")
## var clock := TickClock.new()
## clock.anchor(welcome_tick, welcome_tick_ms)
## [/codeblock]

## Returned by [method estimated_tick] before [method anchor] has been called.
##
## Server ticks start at 0 and only ever increase (PROTOCOL.md, "Clock"), so a
## negative tick cannot collide with a real one: "not anchored yet" is
## distinguishable from "tick 0". Callers check [method is_anchored] rather than
## comparing against this, but the value is named so a stray one in a log is
## readable.
##
## Deliberately a sentinel and not a [method @GlobalScope.push_error]: an
## unanchored clock is the normal state between process start and the first
## [code]welcome[/code], and erroring on every frame of it would bury the log.
const UNANCHORED_TICK := -1

const _USEC_PER_MSEC := 1000

var _anchor_tick := UNANCHORED_TICK
var _anchor_usec := 0
var _tick_usec := 0
## Monotonic time source in microseconds. Injectable so a test can simulate a
## long stall without sleeping through it; production leaves it defaulted.
var _now_usec: Callable
## The object the time source is bound to, if any.
##
## A [Callable] holds an object id, not a reference, so a [RefCounted] time
## source whose last other reference goes out of scope is freed underneath the
## clock and every later read fails on a null instance. The clock owns its time
## source: keeping the object here is what makes that ownership real.
var _now_usec_owner: Object = null


## [param now_usec_source] must return microseconds from a [b]monotonic[/b]
## source. Defaults to [method Time.get_ticks_usec], which is monotonic and
## unaffected by the system clock being changed underneath the process.
func _init(now_usec_source: Callable = Callable()) -> void:
	_now_usec = now_usec_source if now_usec_source.is_valid() else Time.get_ticks_usec
	_now_usec_owner = _now_usec.get_object()


## Records the anchor: server tick [param anchor_tick] was current at the
## monotonic instant of this call, and one tick lasts [param tick_ms].
##
## Calling it again re-anchors. That is the intended path for a reconnect and,
## from M2, for a drift-correcting heartbeat.
func anchor(anchor_tick: int, tick_ms: int) -> void:
	if anchor_tick < 0:
		push_error("TickClock.anchor: anchor_tick must be >= 0, got %d" % anchor_tick)
		return
	if tick_ms <= 0:
		push_error("TickClock.anchor: tick_ms must be > 0, got %d" % tick_ms)
		return
	_anchor_tick = anchor_tick
	_tick_usec = tick_ms * _USEC_PER_MSEC
	_anchor_usec = _now_usec.call()


func is_anchored() -> bool:
	return _anchor_tick != UNANCHORED_TICK


## The tick the server is estimated to be on right now.
##
## Returns [constant UNANCHORED_TICK] until [method anchor] is called.
##
## The estimate lags the server by one-way latency [b]plus however far into a
## tick the anchoring [code]welcome[/code] was composed[/b]. A connection is
## answered on the world goroutine's event arm and not inside
## [code]step[/code] ([code]server/internal/game/world.go[/code],
## [code]Run[/code]), so that second term lands anywhere in
## [code][0, tick_ms)[/code] and is a different amount for every client.
##
## [b]Two clients reading the same tick number are therefore not reading it at
## the same instant[/b], and nothing a client can observe today narrows that
## down: [code]welcome[/code] and [code]path[/code] are the only frames carrying
## a tick, and both are composed mid-tick. Anything that needs two clients to
## act together must rendezvous on a shared event rather than on a tick number;
## [code]pickup_demo.gd[/code] is the worked example.
##
## The same offset is why a freshly arrived [code]path[/code] can carry a
## [code]start_tick[/code] ahead of the estimate; see
## [code]polyline_walker.gd[/code], which clamps that case rather than
## rewinding.
func estimated_tick() -> int:
	return estimated_tick_at(_now_usec.call())


## The tick the server is estimated to be on at monotonic time [param at_usec].
##
## Any moment, before or after now. The estimate is a formula over the anchor
## and not a running count, so naming a moment costs what naming now costs. A
## caller holding a moment must ask about that moment rather than reading
## [method estimated_tick] beside it, or the two reads can land either side of a
## tick boundary and disagree by one.
##
## [method @GlobalScope.floori] rather than integer division: truncation and
## floor disagree on negatives, [param at_usec] may precede the anchor, and a
## caller may inject a time source this class cannot vouch for. The formula in
## PROTOCOL.md says floor.
func estimated_tick_at(at_usec: int) -> int:
	if not is_anchored():
		return UNANCHORED_TICK
	return _anchor_tick + floori(float(at_usec - _anchor_usec) / float(_tick_usec))


## Milliseconds per tick as reported by the server, or 0 before anchoring.
##
## The walker needs it to turn a tick difference into seconds, and it is the
## only place the client learns it. Nothing here hardcodes 150 (NOTES.md,
## "Tick rate").
func tick_ms() -> int:
	if not is_anchored():
		return 0
	return _tick_usec / _USEC_PER_MSEC
