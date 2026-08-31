extends RefCounted

## Tests for [code]scripts/polyline_walker.gd[/code], with no scene tree at all.
##
## This suite is a [RefCounted]. It never calls [method Node.get_tree], never
## instances a scene, and the runner executes it from
## [method SceneTree._initialize] before any scene has been loaded. That is the
## practical proof that the walker is pure logic and that "game logic never
## reaches into the visual tree" (CLAUDE.md) actually holds in the code rather
## than only in the comments.
##
## Every expectation below is hand-computable. The fixtures use a 100ms tick, not
## the project's 150ms, so that a walker which quietly assumed the real tick
## length would fail here.

const PolylineWalker := preload("res://scripts/polyline_walker.gd")
const Assertions := preload("res://tests/assertions.gd")

## Fixture tick length. Deliberately not 150: this is test data, not the game's
## tick, and picking a different number is what catches a hardcoded one.
const TICK_MS := 100
const TICK_SECONDS := 0.1

## Float32 round-trips through PackedVector2Array, so exact equality is the
## wrong assertion even for values that are exact in decimal.
const POSITION_EPSILON := 1.0e-5
## Durations are float64 arithmetic over float32 inputs; 1e-5 s is four orders
## of magnitude below a tick and well above the representation error.
const DURATION_EPSILON := 1.0e-5

## An L: 3 units east, then 4 units north. Total length 7.
##
## A [code]static var[/code] and not a [code]const[/code]: a
## [PackedVector2Array] constructor is not a constant expression, and declaring
## it as one fails to parse the whole script with a cascade of unrelated errors.
static var CORNER_PATH := PackedVector2Array(
	[Vector2(0.0, 0.0), Vector2(3.0, 0.0), Vector2(3.0, 4.0)]
)
const CORNER_START_TICK := 500
## 2 units/second over a 7 unit polyline is 3.5 seconds, which is 35 ticks.
const CORNER_SPEED := 2.0


func run(assertions: Assertions) -> void:
	_test_starts_at_first_point(assertions)
	_test_mid_segment_on_a_multi_segment_polyline(assertions)
	_test_past_the_end_holds_at_the_final_point(assertions)
	_test_negative_elapsed_clamps_to_the_first_point(assertions)
	_test_zero_length_segment_is_instantly_complete(assertions)
	_test_single_repeated_point_produces_no_nan(assertions)
	_test_a_new_path_replaces_the_old_one_outright(assertions)
	_test_total_traversal_time_is_length_over_speed(assertions)
	_test_heading_follows_the_current_segment(assertions)
	print("  (the three ERROR lines below are the rejections under test)")
	_test_malformed_paths_are_rejected(assertions)
	assertions.finish()


func _corner_walker() -> PolylineWalker:
	var walker := PolylineWalker.new(TICK_MS)
	walker.set_path(CORNER_PATH, CORNER_START_TICK, CORNER_SPEED)
	return walker


## points[0] is the position at start_tick (PROTOCOL.md, `path`).
func _test_starts_at_first_point(assertions: Assertions) -> void:
	var walker := _corner_walker()
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK),
		CORNER_PATH[0],
		POSITION_EPSILON,
		"position at start_tick is points[0]",
	)


## 15 ticks is 1.5s, which at 2 u/s is 3.0 units: exactly the corner.
## 30 ticks is 3.0s, which is 6.0 units: 3.0 units up the second segment.
## 35 ticks is 3.5s, which is 7.0 units: 4.0 units up the second segment.
func _test_mid_segment_on_a_multi_segment_polyline(assertions: Assertions) -> void:
	var walker := _corner_walker()
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 15),
		Vector2(3.0, 0.0),
		POSITION_EPSILON,
		"3.0 units in lands exactly on the corner",
	)
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 30),
		Vector2(3.0, 3.0),
		POSITION_EPSILON,
		"6.0 units in is 3.0 units up the second segment",
	)
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 35),
		Vector2(3.0, 4.0),
		POSITION_EPSILON,
		"7.0 units in is at the far end of the second segment",
	)
	# Half a tick in: the walker interpolates between ticks rather than
	# snapping to them, but positions are only sampled at whole ticks, so the
	# check that matters is that a tick it was never given still resolves.
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 5),
		Vector2(1.0, 0.0),
		POSITION_EPSILON,
		"5 ticks in is 1.0 unit along the first segment",
	)


## No overshoot and no wrap (PROTOCOL.md, `path`).
func _test_past_the_end_holds_at_the_final_point(assertions: Assertions) -> void:
	var walker := _corner_walker()
	var last := CORNER_PATH[CORNER_PATH.size() - 1]
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 35),
		last,
		POSITION_EPSILON,
		"at exactly the end tick the walker is at the final point",
	)
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 36),
		last,
		POSITION_EPSILON,
		"one tick past the end holds at the final point",
	)
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 1_000_000),
		last,
		POSITION_EPSILON,
		"a million ticks past the end still holds at the final point",
	)
	assertions.check(
		not walker.is_finished_at_tick(CORNER_START_TICK + 34),
		"not finished one tick before the end",
	)
	assertions.check(
		walker.is_finished_at_tick(CORNER_START_TICK + 35),
		"finished at the end tick",
	)


## The client's estimate lags the server, so a fresh path can start in the
## client's perceived future. Negative elapsed means "not started", not "rewind"
## (PROTOCOL.md, "Clock").
func _test_negative_elapsed_clamps_to_the_first_point(assertions: Assertions) -> void:
	var walker := _corner_walker()
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK - 1),
		CORNER_PATH[0],
		POSITION_EPSILON,
		"one tick before start_tick clamps to points[0]",
	)
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK - 10_000),
		CORNER_PATH[0],
		POSITION_EPSILON,
		"far before start_tick clamps to points[0], it does not walk backwards",
	)
	assertions.check_position_near(
		walker.position_at_tick(0),
		CORNER_PATH[0],
		POSITION_EPSILON,
		"tick 0 against a start_tick of %d clamps to points[0]" % CORNER_START_TICK,
	)


## Clicking the ground you already stand on is the case that produces one. The
## divide it would cause yields a NaN position that is painful to trace
## (PROTOCOL.md, `path`, "Degenerate paths").
func _test_zero_length_segment_is_instantly_complete(assertions: Assertions) -> void:
	var points := PackedVector2Array(
		[Vector2(0.0, 0.0), Vector2(2.0, 0.0), Vector2(2.0, 0.0), Vector2(2.0, 3.0)]
	)
	var walker := PolylineWalker.new(TICK_MS)
	walker.set_path(points, 0, 1.0)

	assertions.check_near(
		walker.total_length(), 5.0, POSITION_EPSILON, "a zero-length segment adds no length"
	)
	# Sample every tick across the whole walk, including the tick that lands
	# exactly on the degenerate segment, and past the end.
	var all_finite := true
	for tick in range(-5, 60):
		var sample := walker.position_at_tick(tick)
		if not is_finite(sample.x) or not is_finite(sample.y):
			all_finite = false
	assertions.check(all_finite, "no sample across the whole walk is NaN or infinite")

	assertions.check_position_near(
		walker.position_at_tick(20),
		Vector2(2.0, 0.0),
		POSITION_EPSILON,
		"2.0s lands exactly on the zero-length segment",
	)
	assertions.check_position_near(
		walker.position_at_tick(30),
		Vector2(2.0, 1.0),
		POSITION_EPSILON,
		"3.0s is past the zero-length segment and 1.0 unit up the last one",
	)
	assertions.check_finite(
		walker.direction_at_tick(20), "the heading on the zero-length segment is finite"
	)
	assertions.check_position_near(
		walker.direction_at_tick(20),
		Vector2(0.0, 1.0),
		POSITION_EPSILON,
		"the heading at the zero-length segment is the next real segment's",
	)


func _test_single_repeated_point_produces_no_nan(assertions: Assertions) -> void:
	var here := Vector2(4.0, -7.0)
	var walker := PolylineWalker.new(TICK_MS)
	walker.set_path(PackedVector2Array([here, here]), 100, 3.0)

	assertions.check_near(
		walker.total_length(), 0.0, POSITION_EPSILON, "a repeated point has zero length"
	)
	assertions.check_near(
		walker.total_duration_seconds(),
		0.0,
		DURATION_EPSILON,
		"a zero-length path takes zero time",
	)
	for tick in [0, 100, 101, 1000]:
		assertions.check_position_near(
			walker.position_at_tick(tick),
			here,
			POSITION_EPSILON,
			"a repeated point holds still at tick %d with no NaN" % tick,
		)
	assertions.check(walker.is_finished_at_tick(100), "a zero-length path is finished immediately")
	assertions.check_finite(walker.direction_at_tick(100), "its heading is finite")

	# One point, not two. Same shape, and the arc table has a single entry.
	var single := PolylineWalker.new(TICK_MS)
	single.set_path(PackedVector2Array([here]), 100, 3.0)
	assertions.check_position_near(
		single.position_at_tick(500),
		here,
		POSITION_EPSILON,
		"a one-point path holds at that point with no NaN",
	)


## A new path replaces the current one outright: no blending, no queue
## (PROTOCOL.md, `path`).
func _test_a_new_path_replaces_the_old_one_outright(assertions: Assertions) -> void:
	var walker := _corner_walker()
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 10),
		Vector2(2.0, 0.0),
		POSITION_EPSILON,
		"mid-walk on the first path, 2.0 units along",
	)

	# The server re-anchors a replacement at the player's real position, so the
	# new points[0] is where the old path had reached.
	var replacement := PackedVector2Array([Vector2(2.0, 0.0), Vector2(2.0, -6.0)])
	walker.set_path(replacement, CORNER_START_TICK + 10, 3.0)

	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 10),
		Vector2(2.0, 0.0),
		POSITION_EPSILON,
		"the replacement starts at its own points[0]",
	)
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 20),
		Vector2(2.0, -3.0),
		POSITION_EPSILON,
		"10 ticks later it is 3.0 units down the replacement, not along the old path",
	)
	assertions.check_near(
		walker.total_length(),
		6.0,
		POSITION_EPSILON,
		"total length is the replacement's, the old 7.0 is gone",
	)
	assertions.check_near(
		walker.total_duration_seconds(),
		2.0,
		DURATION_EPSILON,
		"total duration is the replacement's",
	)
	assertions.check(
		walker.start_tick() == CORNER_START_TICK + 10,
		"start_tick is the replacement's (%d)" % walker.start_tick(),
	)
	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 35),
		Vector2(2.0, -6.0),
		POSITION_EPSILON,
		"at the old path's end tick it holds at the replacement's final point",
	)


func _test_total_traversal_time_is_length_over_speed(assertions: Assertions) -> void:
	var walker := _corner_walker()
	assertions.check_near(
		walker.total_length(), 7.0, POSITION_EPSILON, "the L is 3 + 4 = 7 units long"
	)
	assertions.check_near(
		walker.total_duration_seconds(),
		7.0 / CORNER_SPEED,
		DURATION_EPSILON,
		"traversal time is length / speed",
	)

	# A second fixture at the project's real 150ms tick, and at a speed that
	# does not divide evenly, so the check is not an artifact of round numbers.
	var awkward := PolylineWalker.new(150)
	var points := PackedVector2Array(
		[Vector2(-1.5, 2.25), Vector2(4.5, 2.25), Vector2(4.5, 10.25)]
	)
	awkward.set_path(points, 7, 3.7)
	var expected_length := 6.0 + 8.0
	assertions.check_near(
		awkward.total_length(), expected_length, POSITION_EPSILON, "awkward fixture length"
	)
	assertions.check_near(
		awkward.total_duration_seconds(),
		expected_length / 3.7,
		DURATION_EPSILON,
		"awkward fixture traversal time is length / speed",
	)
	# 14 / 3.7 = 3.783783...s, which is 25.225 ticks at 150ms. Not finished at
	# 25, finished at 26.
	assertions.check(
		not awkward.is_finished_at_tick(7 + 25), "awkward fixture is not finished at tick 25"
	)
	assertions.check(
		awkward.is_finished_at_tick(7 + 26), "awkward fixture is finished at tick 26"
	)


func _test_heading_follows_the_current_segment(assertions: Assertions) -> void:
	var walker := _corner_walker()
	assertions.check_position_near(
		walker.direction_at_tick(CORNER_START_TICK),
		Vector2(1.0, 0.0),
		POSITION_EPSILON,
		"heading at the start is along the first segment",
	)
	assertions.check_position_near(
		walker.direction_at_tick(CORNER_START_TICK - 50),
		Vector2(1.0, 0.0),
		POSITION_EPSILON,
		"heading before the start is still the first segment's",
	)
	assertions.check_position_near(
		walker.direction_at_tick(CORNER_START_TICK + 20),
		Vector2(0.0, 1.0),
		POSITION_EPSILON,
		"heading past the corner is along the second segment",
	)
	assertions.check(
		walker.direction_at_tick(CORNER_START_TICK + 40) == Vector2.ZERO,
		"heading at the end is zero, meaning hold whatever facing you have",
	)


## Invalid input is rejected loudly and leaves the current path alone, rather
## than being absorbed into a state nothing can explain later.
func _test_malformed_paths_are_rejected(assertions: Assertions) -> void:
	var walker := _corner_walker()
	var before := walker.position_at_tick(CORNER_START_TICK + 10)

	# push_error() is what "loudly" means here; these three calls each emit one,
	# which is why the runner's log has errors in it on a passing run.
	walker.set_path(PackedVector2Array(), 0, 1.0)
	walker.set_path(CORNER_PATH, 0, 0.0)
	walker.set_path(PackedVector2Array([Vector2(0.0, 0.0), Vector2(NAN, 1.0)]), 0, 1.0)

	assertions.check_position_near(
		walker.position_at_tick(CORNER_START_TICK + 10),
		before,
		POSITION_EPSILON,
		"three rejected paths left the walker on its original path",
	)
	assertions.check(
		walker.start_tick() == CORNER_START_TICK,
		"a rejected path did not move start_tick (%d)" % walker.start_tick(),
	)
