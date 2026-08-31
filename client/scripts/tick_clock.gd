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
## Returns [constant UNANCHORED_TICK] until [method anchor] is called. The
## estimate lags the server by roughly one-way latency, which is why a freshly
## arrived [code]path[/code] can carry a [code]start_tick[/code] ahead of it;
## see [code]polyline_walker.gd[/code], which clamps that case rather than
## rewinding.
func estimated_tick() -> int:
	if not is_anchored():
		return UNANCHORED_TICK
	return _anchor_tick + _elapsed_ticks()


## Milliseconds per tick as reported by the server, or 0 before anchoring.
##
## The walker needs it to turn a tick difference into seconds, and it is the
## only place the client learns it. Nothing here hardcodes 150 (NOTES.md,
## "Tick rate").
func tick_ms() -> int:
	if not is_anchored():
		return 0
	return _tick_usec / _USEC_PER_MSEC


## Whole ticks elapsed since the anchor.
##
## [method @GlobalScope.floori] rather than integer division: truncation and
## floor disagree on negatives, and a caller may inject a time source this class
## cannot vouch for. The formula in PROTOCOL.md says floor.
func _elapsed_ticks() -> int:
	var elapsed_usec: int = _now_usec.call() - _anchor_usec
	return floori(float(elapsed_usec) / float(_tick_usec))
