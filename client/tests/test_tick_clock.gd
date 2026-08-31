extends RefCounted

## Tests for [code]scripts/tick_clock.gd[/code], with no scene tree at all.
##
## Same shape as the walker suite: a [RefCounted] the runner executes from
## [method SceneTree._initialize], before any scene exists.
##
## The load-bearing test is [method _test_a_stall_does_not_lose_ticks]. Every
## other assertion here would also pass for a clock that summed frame deltas.

const TickClock := preload("res://scripts/tick_clock.gd")
const Assertions := preload("res://tests/assertions.gd")

const TICK_MS := 150
const USEC_PER_MSEC := 1000

## The stall to simulate, in ticks. Long enough that a frame-delta clock could
## not plausibly have caught up by accident.
const STALL_TICKS := 400

## A real, unfaked stall used by the wall-clock test. Long enough to span
## several ticks and short enough not to pad the suite.
const REAL_STALL_MSEC := 500


## A monotonic time source the test moves by hand, standing in for wall time.
class FakeMonotonicClock extends RefCounted:
	var now_usec := 0

	func read() -> int:
		return now_usec

	func advance_msec(msec: int) -> void:
		now_usec += msec * 1000


func run(assertions: Assertions) -> void:
	_test_unanchored_is_distinguishable_from_tick_zero(assertions)
	_test_one_tick_per_tick_ms(assertions)
	_test_sub_tick_time_floors(assertions)
	_test_a_stall_does_not_lose_ticks(assertions)
	_test_real_monotonic_time_advances_without_frames(assertions)
	_test_re_anchoring_moves_the_origin(assertions)
	print("  (the three ERROR lines below are the rejections under test)")
	_test_invalid_anchors_are_rejected(assertions)
	assertions.finish()


## Before anchoring the clock must be unambiguously un-anchored, not silently
## reporting tick 0. Tick 0 is a real server tick.
func _test_unanchored_is_distinguishable_from_tick_zero(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)

	assertions.check(not clock.is_anchored(), "a fresh clock reports itself un-anchored")
	assertions.check(
		clock.estimated_tick() != 0,
		"an un-anchored estimate is not 0, it is %d" % clock.estimated_tick(),
	)
	assertions.check(
		clock.estimated_tick() == TickClock.UNANCHORED_TICK,
		"an un-anchored estimate is the UNANCHORED_TICK sentinel",
	)
	assertions.check(
		TickClock.UNANCHORED_TICK < 0,
		"the sentinel is negative, so it cannot collide with a server tick",
	)
	assertions.check(clock.tick_ms() == 0, "an un-anchored clock reports no tick length")

	# Anchoring at server tick 0 must then be distinguishable from not being
	# anchored, which is the whole point of the sentinel.
	clock.anchor(0, TICK_MS)
	assertions.check(clock.is_anchored(), "after anchoring at tick 0 the clock is anchored")
	assertions.check(
		clock.estimated_tick() == 0, "anchored at tick 0 the estimate is 0, not the sentinel"
	)


## estimated_tick = anchor_tick + floor((now - anchor_time) / tick_ms).
func _test_one_tick_per_tick_ms(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)
	clock.anchor(142, TICK_MS)

	assertions.check(clock.estimated_tick() == 142, "no time elapsed means the anchor tick")
	assertions.check(clock.tick_ms() == TICK_MS, "the clock reports the tick length it was given")

	for step in range(1, 11):
		fake.advance_msec(TICK_MS)
		assertions.check(
			clock.estimated_tick() == 142 + step,
			"%d x tick_ms after the anchor the estimate is %d, got %d"
			% [step, 142 + step, clock.estimated_tick()],
		)


func _test_sub_tick_time_floors(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)
	clock.anchor(10, TICK_MS)

	fake.now_usec += (TICK_MS - 1) * USEC_PER_MSEC
	assertions.check(
		clock.estimated_tick() == 10, "one millisecond short of a tick has not ticked over"
	)
	fake.now_usec += USEC_PER_MSEC
	assertions.check(clock.estimated_tick() == 11, "the next millisecond ticks over")


## [b]The assertion that protects the whole design.[/b]
##
## Monotonic time jumps by [constant STALL_TICKS] ticks with zero frames run in
## between: this suite is a plain function call, so no frame can occur inside it.
## A clock that accumulated frame deltas would report the anchor tick, because it
## saw no frames. This one must report the full elapsed interval.
##
## A minimized or stalled window is exactly this case, and a frame-delta clock
## would fall permanently behind it with nothing to correct it (PROTOCOL.md,
## "Clock").
func _test_a_stall_does_not_lose_ticks(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)
	clock.anchor(1000, TICK_MS)

	fake.advance_msec(STALL_TICKS * TICK_MS)

	assertions.check(
		clock.estimated_tick() == 1000 + STALL_TICKS,
		"a %d-tick stall with zero frames advances the estimate by %d, got %d"
		% [STALL_TICKS, STALL_TICKS, clock.estimated_tick() - 1000],
	)
	assertions.check(
		clock.estimated_tick() != 1000,
		"the estimate did not sit at the anchor the way a frame-delta clock would",
	)

	# And it recovers with no catch-up: the next read after the stall is
	# correct immediately, not gradually.
	fake.advance_msec(TICK_MS)
	assertions.check(
		clock.estimated_tick() == 1000 + STALL_TICKS + 1,
		"the tick after the stall is the very next tick, with no catch-up ramp",
	)


## The same property against the real default time source, so the fake above
## cannot be the only thing that makes it hold.
##
## [method OS.delay_msec] blocks this thread. Nothing renders, no frame is
## processed, and no [code]delta[/code] is delivered to anything for the whole
## interval. A clock that needed frames would report no progress.
func _test_real_monotonic_time_advances_without_frames(assertions: Assertions) -> void:
	var clock := TickClock.new()
	clock.anchor(0, TICK_MS)
	var before := clock.estimated_tick()

	OS.delay_msec(REAL_STALL_MSEC)

	var advanced := clock.estimated_tick() - before
	var expected := REAL_STALL_MSEC / TICK_MS
	assertions.check(
		advanced >= expected,
		(
			"a real %dms stall with zero frames advanced the default clock by at least %d ticks, got %d"
			% [REAL_STALL_MSEC, expected, advanced]
		),
	)
	# The scheduler can overshoot a delay but cannot undershoot it by a tick,
	# so an upper bound this loose still catches a runaway estimate.
	assertions.check(
		advanced <= expected + 4,
		"the real stall did not overshoot wildly (%d ticks for %dms)" % [advanced, REAL_STALL_MSEC],
	)


## Re-anchoring is how a reconnect, and later an M2 heartbeat, correct drift.
func _test_re_anchoring_moves_the_origin(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)
	clock.anchor(100, TICK_MS)
	fake.advance_msec(10 * TICK_MS)
	assertions.check(clock.estimated_tick() == 110, "first anchor put the estimate at 110")

	clock.anchor(5000, 200)
	assertions.check(clock.estimated_tick() == 5000, "re-anchoring resets to the new anchor tick")
	assertions.check(clock.tick_ms() == 200, "re-anchoring adopts the new tick length")
	fake.advance_msec(600)
	assertions.check(
		clock.estimated_tick() == 5003, "the new tick length is what advances the estimate"
	)


func _test_invalid_anchors_are_rejected(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)

	# Each of these emits a push_error; see the banner the suite prints.
	clock.anchor(-1, TICK_MS)
	assertions.check(not clock.is_anchored(), "a negative anchor_tick is refused")
	clock.anchor(5, 0)
	assertions.check(not clock.is_anchored(), "a zero tick_ms is refused rather than divided by")
	clock.anchor(5, -150)
	assertions.check(not clock.is_anchored(), "a negative tick_ms is refused")

	clock.anchor(5, TICK_MS)
	assertions.check(clock.is_anchored(), "a valid anchor after three refusals still takes")
