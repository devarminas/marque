extends RefCounted

## Turns a [code]path[/code] message's contents into a ground position at any tick.
##
## Pure arithmetic over numbers. It holds no node, touches no scene tree, and
## renders nothing — "game logic never reaches into the visual tree" (CLAUDE.md).
## An avatar reads a position out of it; it never writes one into an avatar. That
## seam is what lets the whole thing be tested headless with no scene at all.
##
## Coordinates are ground-plane [code](x, z)[/code] carried in a [Vector2], where
## [code]x[/code] is world X and [code]y[/code] is world [b]Z[/b]. [code]y[/code]
## is up, never on the wire, and the client's business (PROTOCOL.md,
## "Coordinates").
##
## Typed by [code]preload[/code] rather than by a [code]class_name[/code], per
## NOTES.md, "Godot authoring traps":
##
## [codeblock]
## const PolylineWalker := preload("res://scripts/polyline_walker.gd")
## var walker := PolylineWalker.new(welcome_tick_ms)
## walker.set_path(points, start_tick, speed)
## var here := walker.position_at_tick(clock.estimated_tick())
## [/codeblock]

const _MSEC_PER_SEC := 1000.0

## Seconds per tick, from [code]welcome.tick_ms[/code]. Constant for the life of
## a connection, so it is supplied once at construction rather than repeated on
## every path. There is no default: nothing outside the server may decide what a
## tick lasts (NOTES.md, "Tick rate").
var _tick_seconds := 0.0

var _points := PackedVector2Array()
var _start_tick := 0
var _speed := 0.0
## Arc length from [code]_points[0][/code] to each point. [code]_arc[0][/code] is
## always 0 and [code]_arc[-1[/code]] is the total polyline length. Precomputed
## because the alternative is re-walking the polyline on every frame.
var _arc := PackedFloat64Array()


## [param tick_ms] is [code]welcome.tick_ms[/code]. Must be positive.
func _init(tick_ms: int) -> void:
	if tick_ms <= 0:
		push_error("PolylineWalker: tick_ms must be > 0, got %d" % tick_ms)
		return
	_tick_seconds = float(tick_ms) / _MSEC_PER_SEC


## Adopts a [code]path[/code] message.
##
## [param points] are ground-plane [code](x, z)[/code] waypoints, of which
## [code]points[0][/code] is the walker's position at [param start_tick].
## [param speed] is world units per second, constant across the whole polyline
## (PROTOCOL.md, [code]path[/code]).
##
## The new path [b]replaces[/b] the current one outright. There is no blending
## and no queue: the server already re-anchors a mid-walk replacement so that its
## [code]points[0][/code] is where the player actually is, and a client that
## blended on top of that would disagree with the server about where it stood.
##
## A malformed path is rejected loudly and leaves the current path in place. An
## avatar that keeps walking its last known path is a better failure than one
## that freezes or teleports, and the [method @GlobalScope.push_error] is what
## makes it findable.
func set_path(points: PackedVector2Array, start_tick: int, speed: float) -> void:
	if _tick_seconds <= 0.0:
		push_error("PolylineWalker.set_path: walker was constructed with an invalid tick_ms")
		return
	if points.is_empty():
		push_error("PolylineWalker.set_path: points is empty")
		return
	if not (speed > 0.0) or not is_finite(speed):
		push_error("PolylineWalker.set_path: speed must be finite and > 0, got %f" % speed)
		return
	for index in points.size():
		var point := points[index]
		if not is_finite(point.x) or not is_finite(point.y):
			push_error("PolylineWalker.set_path: points[%d] is not finite: %v" % [index, point])
			return

	_points = points
	_start_tick = start_tick
	_speed = speed
	_rebuild_arc_lengths()


func has_path() -> bool:
	return not _points.is_empty()


## Where the walker stands at [param tick].
##
## Precondition: [method has_path]. Ground-plane [code](x, z)[/code].
##
## Two clamps, both mandated by PROTOCOL.md:
##
## - [b]Elapsed time is clamped at zero.[/b] The client's tick estimate lags the
##   server by roughly one-way latency, so a freshly arrived path can carry a
##   [code]start_tick[/code] in the client's perceived future. Negative elapsed
##   means "has not started yet", not "rewind".
## - [b]Past the end it holds at the final point.[/b] No overshoot, no wrap.
func position_at_tick(tick: int) -> Vector2:
	if not has_path():
		push_error("PolylineWalker.position_at_tick: no path set")
		return Vector2.ZERO
	return _point_at_distance(_distance_travelled_at_tick(tick))


## Unit heading along the segment being traversed at [param tick], or
## [constant Vector2.ZERO] once the walk is over or when the path has no length.
##
## Facing is presentation, not position, so it is a separate call: an avatar that
## wants to turn toward its direction of travel asks for it, and one that does
## not never pays for it. Zero means "no opinion" — hold whatever facing you
## have rather than snapping to a default.
func direction_at_tick(tick: int) -> Vector2:
	if not has_path():
		push_error("PolylineWalker.direction_at_tick: no path set")
		return Vector2.ZERO

	var travelled := _distance_travelled_at_tick(tick)
	if travelled >= total_length():
		return Vector2.ZERO

	for index in range(1, _points.size()):
		if _arc[index] <= travelled:
			continue
		# _arc is strictly increasing past a zero-length segment, so this
		# segment has length and normalizing it cannot divide by zero.
		return (_points[index] - _points[index - 1]).normalized()
	return Vector2.ZERO


## True once [param tick] is at or past the end of the polyline.
func is_finished_at_tick(tick: int) -> bool:
	if not has_path():
		return true
	return _distance_travelled_at_tick(tick) >= total_length()


## Total polyline length in world units. Zero for a single point, or for a path
## whose points all coincide.
func total_length() -> float:
	if _arc.is_empty():
		return 0.0
	return _arc[_arc.size() - 1]


## Wall time the whole polyline takes at [member _speed], in seconds.
func total_duration_seconds() -> float:
	if not has_path():
		return 0.0
	return total_length() / _speed


## The tick the path started at, as the server stated it.
func start_tick() -> int:
	return _start_tick


## Distance covered by [param tick], never negative.
func _distance_travelled_at_tick(tick: int) -> float:
	var elapsed_seconds := maxf(0.0, float(tick - _start_tick) * _tick_seconds)
	return elapsed_seconds * _speed


## Position [param distance] along the polyline, clamped to both ends.
##
## [b]A zero-length segment is instantly complete.[/b] Clicking the ground you
## are already standing on is the case that produces one. The server suppresses
## degenerate paths, but two defenses cost nothing and dividing by a zero-length
## segment yields a NaN position that is genuinely painful to trace back here
## (PROTOCOL.md, [code]path[/code], "Degenerate paths").
func _point_at_distance(distance: float) -> Vector2:
	var last_index := _points.size() - 1
	if distance <= 0.0:
		return _points[0]
	if distance >= total_length():
		return _points[last_index]

	for index in range(1, _points.size()):
		if _arc[index] < distance:
			continue
		var segment_length := _arc[index] - _arc[index - 1]
		if segment_length <= 0.0:
			# A zero-length segment is instantly complete: there is nothing to
			# interpolate across and the divide below would be by zero.
			#
			# Both clamps above already make this unreachable for a strictly
			# increasing arc table, which is the second of the two defenses.
			# It stays because it is the one that survives someone changing how
			# the table is built, and because the symptom it prevents is a NaN
			# position with no stack to trace.
			return _points[index]
		var along := (distance - _arc[index - 1]) / segment_length
		return _points[index - 1].lerp(_points[index], along)

	# Unreachable: distance < total_length() means some _arc[index] exceeds it.
	return _points[last_index]


func _rebuild_arc_lengths() -> void:
	_arc.resize(_points.size())
	_arc[0] = 0.0
	for index in range(1, _points.size()):
		_arc[index] = _arc[index - 1] + _points[index - 1].distance_to(_points[index])
