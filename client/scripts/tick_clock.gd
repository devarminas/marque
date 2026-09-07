extends RefCounted


const UNANCHORED_TICK := -1

const _USEC_PER_MSEC := 1000

var _anchor_tick := UNANCHORED_TICK
var _anchor_usec := 0
var _tick_usec := 0
var _now_usec: Callable
var _now_usec_owner: Object = null


func _init(now_usec_source: Callable = Callable()) -> void:
	_now_usec = now_usec_source if now_usec_source.is_valid() else Time.get_ticks_usec
	_now_usec_owner = _now_usec.get_object()


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


func estimated_tick() -> int:
	return estimated_tick_at(_now_usec.call())


func estimated_tick_at(at_usec: int) -> int:
	if not is_anchored():
		return UNANCHORED_TICK
	return _anchor_tick + floori(float(at_usec - _anchor_usec) / float(_tick_usec))


func phase_usec_at(at_usec: int) -> int:
	if not is_anchored() or _tick_usec <= 0:
		return 0
	return posmod(at_usec - _anchor_usec, _tick_usec)


# Never click from inside the tick: wait for the next guard so one-way latency
# cannot sit on the server's late edge (ARM-67 run 18).
func next_guard_usec(from_usec: int, guard_usec: int) -> int:
	if not is_anchored() or _tick_usec <= 0:
		return from_usec
	if guard_usec <= 0 or guard_usec >= _tick_usec:
		push_error(
			"TickClock.next_guard_usec: guard_usec must be in (0, tick_usec), got %d of %d"
			% [guard_usec, _tick_usec]
		)
		return from_usec
	var phase := phase_usec_at(from_usec)
	if phase < guard_usec:
		return from_usec + (guard_usec - phase)
	return from_usec + (_tick_usec - phase) + guard_usec


func tick_ms() -> int:
	if not is_anchored():
		return 0
	return _tick_usec / _USEC_PER_MSEC
