extends RefCounted


const _MSEC_PER_SEC := 1000.0

var _tick_seconds := 0.0

var _points := PackedVector2Array()
var _start_tick := 0
var _speed := 0.0
var _arc := PackedFloat64Array()


func _init(tick_ms: int) -> void:
	if tick_ms <= 0:
		push_error("PolylineWalker: tick_ms must be > 0, got %d" % tick_ms)
		return
	_tick_seconds = float(tick_ms) / _MSEC_PER_SEC


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


func position_at_tick(tick: int) -> Vector2:
	if not has_path():
		push_error("PolylineWalker.position_at_tick: no path set")
		return Vector2.ZERO
	return _point_at_distance(_distance_travelled_at_tick(tick))


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
		return (_points[index] - _points[index - 1]).normalized()
	return Vector2.ZERO


func is_finished_at_tick(tick: int) -> bool:
	if not has_path():
		return true
	return _distance_travelled_at_tick(tick) >= total_length()


func total_length() -> float:
	if _arc.is_empty():
		return 0.0
	return _arc[_arc.size() - 1]


func total_duration_seconds() -> float:
	if not has_path():
		return 0.0
	return total_length() / _speed


func start_tick() -> int:
	return _start_tick


func _distance_travelled_at_tick(tick: int) -> float:
	var elapsed_seconds := maxf(0.0, float(tick - _start_tick) * _tick_seconds)
	return elapsed_seconds * _speed


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
			return _points[index]
		var along := (distance - _arc[index - 1]) / segment_length
		return _points[index - 1].lerp(_points[index], along)

	return _points[last_index]


func _rebuild_arc_lengths() -> void:
	_arc.resize(_points.size())
	_arc[0] = 0.0
	for index in range(1, _points.size()):
		_arc[index] = _arc[index - 1] + _points[index - 1].distance_to(_points[index])
