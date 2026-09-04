extends RefCounted

## Tests for [code]scripts/tick_clock.gd[/code], with no scene tree at all.
##
## Same shape as the walker suite: a [RefCounted] the runner executes from
## [method SceneTree._initialize], before any scene exists.
##
## The load-bearing test is [method _test_a_stall_does_not_lose_ticks]. Every
## other assertion here would also pass for a clock that summed frame deltas.

const TickClock := preload("res://scripts/tick_clock.gd")
const PickupDemo := preload("res://scripts/pickup_demo.gd")
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
	_test_estimating_at_a_named_moment(assertions)
	_test_a_tick_number_is_not_a_moment(assertions)
	_test_phase_is_the_remainder_into_the_tick(assertions)
	_test_a_half_tick_lead_still_splits_a_server_edge(assertions)
	_test_nearby_scenario_observations_share_a_deadline(assertions)
	_test_a_next_guard_click_keeps_two_receipts_on_one_server_tick(assertions)
	_test_a_next_guard_click_waits_out_of_a_late_interior(assertions)
	_test_a_next_guard_click_survives_a_late_edge_and_an_overshoot(assertions)
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


func _test_estimating_at_a_named_moment(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)

	assertions.check(
		clock.estimated_tick_at(0) == TickClock.UNANCHORED_TICK,
		"an un-anchored clock knows nothing about any moment, not just about now",
	)

	clock.anchor(500, TICK_MS)
	var anchored_at := fake.now_usec
	assertions.check(
		clock.estimated_tick_at(anchored_at) == 500, "the anchor instant estimates the anchor tick"
	)
	assertions.check(
		clock.estimated_tick_at(anchored_at + 20 * TICK_MS * USEC_PER_MSEC) == 520,
		"twenty ticks past the anchor estimates twenty ticks on",
	)
	assertions.check(
		clock.estimated_tick_at(anchored_at - USEC_PER_MSEC) == 499,
		"a moment before the anchor floors backwards rather than truncating towards it",
	)

	fake.advance_msec(37)
	var moment := fake.now_usec
	for lead: int in [1, 20, 400]:
		assertions.check(
			(clock.estimated_tick_at(moment + lead * TICK_MS * USEC_PER_MSEC)
				== clock.estimated_tick_at(moment) + lead),
			"a %d-tick lead from an arbitrary moment names a tick %d on" % [lead, lead],
		)

	assertions.check(
		clock.estimated_tick_at(fake.now_usec) == clock.estimated_tick(),
		"estimating at now is estimating now",
	)


func _test_a_tick_number_is_not_a_moment(assertions: Assertions) -> void:
	var shared := FakeMonotonicClock.new()
	var early_clock := TickClock.new(shared.read)
	var late_clock := TickClock.new(shared.read)

	var offset_msec := 100
	early_clock.anchor(900, TICK_MS)
	shared.advance_msec(offset_msec)
	late_clock.anchor(900, TICK_MS)

	assertions.check(
		early_clock.estimated_tick() == late_clock.estimated_tick(),
		"at one instant both clients report tick %d" % early_clock.estimated_tick(),
	)

	var target := 900 + 20
	var early_msec := -1
	var late_msec := -1
	for step in range(0, 40 * TICK_MS):
		var now_msec := offset_msec + step
		if early_msec < 0 and early_clock.estimated_tick() >= target:
			early_msec = now_msec
		if late_msec < 0 and late_clock.estimated_tick() >= target:
			late_msec = now_msec
		shared.advance_msec(1)

	assertions.check(
		early_msec >= 0 and late_msec >= 0, "both clocks reached the rendezvous tick"
	)
	assertions.check(
		late_msec - early_msec == offset_msec,
		(
			"the two clients act %dms apart on the same tick number, the whole offset between "
			% (late_msec - early_msec)
			+ "their anchors; want %d" % offset_msec
		),
	)


func _test_phase_is_the_remainder_into_the_tick(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)
	assertions.check(clock.phase_usec_at(0) == 0, "an unanchored clock has no phase")

	clock.anchor(40, TICK_MS)
	var tick_usec := TICK_MS * USEC_PER_MSEC
	assertions.check(clock.phase_usec_at(fake.now_usec) == 0, "the anchor instant is phase 0")
	fake.advance_msec(40)
	assertions.check(
		clock.phase_usec_at(fake.now_usec) == 40 * USEC_PER_MSEC,
		"40ms into a tick is phase 40000, got %d" % clock.phase_usec_at(fake.now_usec),
	)
	fake.advance_msec(TICK_MS)
	assertions.check(
		clock.phase_usec_at(fake.now_usec) == 40 * USEC_PER_MSEC,
		"one tick later the phase repeats, got %d" % clock.phase_usec_at(fake.now_usec),
	)
	assertions.check(
		clock.next_guard_usec(fake.now_usec - 40 * USEC_PER_MSEC, tick_usec / 3)
			== fake.now_usec - 40 * USEC_PER_MSEC + tick_usec / 3,
		"a click at phase 0 waits until the guard",
	)


func _test_a_half_tick_lead_still_splits_a_server_edge(assertions: Assertions) -> void:
	var pair := _run18_clocks()
	var tick_usec := TICK_MS * USEC_PER_MSEC
	var ready: int = pair["ready"]
	var half_tick_click := ready + tick_usec / 2
	var recv_a: int = half_tick_click + int(pair["send_a"])
	var recv_b: int = half_tick_click + int(pair["overshoot"]) + int(pair["send_b"])
	assertions.check(
		_server_tick(recv_a, tick_usec) + 1 == _server_tick(recv_b, tick_usec),
		(
			"the half-tick deadline still yields adjacent server ticks (%d then %d); "
			% [_server_tick(recv_a, tick_usec), _server_tick(recv_b, tick_usec)]
			+ "that is the residual F1 left"
		),
	)


func _test_nearby_scenario_observations_share_a_deadline(assertions: Assertions) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)
	clock.anchor(0, TICK_MS)
	var tick_usec := TICK_MS * USEC_PER_MSEC
	var early := 70 * USEC_PER_MSEC
	var late := early + 10 * USEC_PER_MSEC
	assertions.check(
		PickupDemo.click_deadline_usec(early, clock) == PickupDemo.click_deadline_usec(late, clock),
		"two roster observations 10ms apart still name one click deadline",
	)
	var quantum := PickupDemo.click_quantum_usec(tick_usec)
	assertions.check(
		PickupDemo.click_deadline_usec(quantum - USEC_PER_MSEC, clock)
			!= PickupDemo.click_deadline_usec(quantum + USEC_PER_MSEC, clock),
		"observations on opposite sides of a quantum still differ by one bucket",
	)
	var pair := _run18_clocks()
	var clock_a: TickClock = pair["clock_a"]
	var clock_b: TickClock = pair["clock_b"]
	var scenario_a: int = pair["scenario"]
	var scenario_b: int = scenario_a + 10 * USEC_PER_MSEC
	var click_a: int = PickupDemo.click_deadline_usec(scenario_a, clock_a)
	var click_b: int = PickupDemo.click_deadline_usec(scenario_b, clock_b)
	var recv_a: int = click_a + int(pair["send_a"])
	var recv_b: int = click_b + int(pair["overshoot"]) + int(pair["send_b"])
	assertions.check(
		_server_tick(recv_a, tick_usec) == _server_tick(recv_b, tick_usec),
		(
			"a quantized next-guard deadline keeps 10ms-apart observations on one server tick, got %d and %d"
			% [_server_tick(recv_a, tick_usec), _server_tick(recv_b, tick_usec)]
		),
	)


func _test_a_next_guard_click_keeps_two_receipts_on_one_server_tick(
	assertions: Assertions,
) -> void:
	var pair := _run18_clocks()
	var tick_usec := TICK_MS * USEC_PER_MSEC
	var clock_a: TickClock = pair["clock_a"]
	var clock_b: TickClock = pair["clock_b"]
	var guard := PickupDemo.click_guard_usec(tick_usec)
	var ready: int = pair["ready"]
	var click_a: int = clock_a.next_guard_usec(ready, guard)
	var click_b: int = clock_b.next_guard_usec(ready, guard)
	var recv_a: int = click_a + int(pair["send_a"])
	var recv_b: int = click_b + int(pair["overshoot"]) + int(pair["send_b"])
	assertions.check(
		_server_tick(recv_a, tick_usec) == _server_tick(recv_b, tick_usec),
		(
			"next-guard clicks land on one server tick, got %d and %d"
			% [_server_tick(recv_a, tick_usec), _server_tick(recv_b, tick_usec)]
		),
	)
	assertions.check(
		clock_a.phase_usec_at(click_a) == guard,
		"client A clicks on the guard, got phase %d" % clock_a.phase_usec_at(click_a),
	)
	assertions.check(
		click_a > ready and click_b > ready,
		"a ready time already past the guard still waits for the next one",
	)


func _test_a_next_guard_click_waits_out_of_a_late_interior(
	assertions: Assertions,
) -> void:
	var fake := FakeMonotonicClock.new()
	var clock := TickClock.new(fake.read)
	fake.now_usec = 2 * USEC_PER_MSEC
	clock.anchor(0, TICK_MS)
	var tick_usec := TICK_MS * USEC_PER_MSEC
	var guard := PickupDemo.click_guard_usec(tick_usec)
	var from := fake.now_usec + guard + 20 * USEC_PER_MSEC
	assertions.check(
		clock.phase_usec_at(from) > guard,
		"the fixture is already past the guard, phase %d" % clock.phase_usec_at(from),
	)
	var click := clock.next_guard_usec(from, guard)
	assertions.check(click > from, "it does not click from inside the tick")
	assertions.check(
		clock.phase_usec_at(click) == guard,
		"the click sits on the next guard, got %d" % clock.phase_usec_at(click),
	)


func _test_a_next_guard_click_survives_a_late_edge_and_an_overshoot(
	assertions: Assertions,
) -> void:
	var pair := _late_edge_clocks()
	var tick_usec := TICK_MS * USEC_PER_MSEC
	var clock_a: TickClock = pair["clock_a"]
	var clock_b: TickClock = pair["clock_b"]
	var ready: int = pair["ready"]
	assertions.check(
		clock_a.phase_usec_at(ready) >= tick_usec - PickupDemo.click_guard_usec(tick_usec),
		"the fixture starts in the late danger zone, phase %d" % clock_a.phase_usec_at(ready),
	)
	var click_a: int = clock_a.next_guard_usec(ready, PickupDemo.click_guard_usec(tick_usec))
	var click_b: int = clock_b.next_guard_usec(ready, PickupDemo.click_guard_usec(tick_usec))
	var recv_a: int = click_a + int(pair["send_a"])
	var recv_b: int = click_b + int(pair["overshoot"]) + int(pair["send_b"])
	assertions.check(
		_server_tick(recv_a, tick_usec) == _server_tick(recv_b, tick_usec),
		(
			"waiting for the next guard keeps both receipts on one server tick, got %d and %d"
			% [_server_tick(recv_a, tick_usec), _server_tick(recv_b, tick_usec)]
		),
	)
	assertions.check(
		click_a > ready and click_b > ready,
		"both clients wait past the late edge rather than clicking on it",
	)


func _run18_clocks() -> Dictionary:
	return _two_heartbeat_clocks(70 * USEC_PER_MSEC)


func _late_edge_clocks() -> Dictionary:
	return _two_heartbeat_clocks(148 * USEC_PER_MSEC)


func _two_heartbeat_clocks(scenario_usec: int) -> Dictionary:
	var fake := FakeMonotonicClock.new()
	var clock_a := TickClock.new(fake.read)
	var clock_b := TickClock.new(fake.read)
	fake.now_usec = 2 * USEC_PER_MSEC
	clock_a.anchor(0, TICK_MS)
	fake.now_usec = 7 * USEC_PER_MSEC
	clock_b.anchor(0, TICK_MS)
	var tick_usec := TICK_MS * USEC_PER_MSEC
	return {
		"clock_a": clock_a,
		"clock_b": clock_b,
		"scenario": scenario_usec,
		"ready": scenario_usec + PickupDemo.CLICK_LEAD_TICKS * tick_usec,
		"send_a": USEC_PER_MSEC,
		"send_b": 8 * USEC_PER_MSEC,
		"overshoot": 3 * USEC_PER_MSEC,
	}


func _server_tick(recv_usec: int, tick_usec: int) -> int:
	return floori(float(recv_usec) / float(tick_usec))


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
