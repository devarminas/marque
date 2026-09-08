extends Node3D


const PolylineWalker := preload("res://scripts/polyline_walker.gd")
const TickClock := preload("res://scripts/tick_clock.gd")

const WALK_ANIM := "ual2/Walk_Carry"
const IDLE_ANIM := "ual2/Idle_FoldArms"
const WALK_CLIP_SPEED := 0.65

var player_id := 0

var clock: TickClock = null

@export var ground_y := 0.0

@export var face_travel_direction := true

# Linear ARM-51.
@export var turn_degrees_per_second := 540.0

var _walker: PolylineWalker = null
var _desired_yaw := 0.0

@onready var _animation: AnimationPlayer = $AnimationPlayer
@onready var _hp_label: Label3D = $HpLabel
@onready var _selection_ring: MeshInstance3D = $SelectionRing


func configure(id: int, tick_ms: int) -> void:
	if id <= 0:
		push_error("PlayerAvatar.configure: player ids start at 1, got %d" % id)
		return
	player_id = id
	_walker = PolylineWalker.new(tick_ms)


func teleport_to(x: float, z: float) -> void:
	position = Vector3(x, ground_y, z)


func set_hit_points(hp: int, max_hp: int) -> void:
	if _hp_label == null:
		return
	_hp_label.text = "%d/%d" % [hp, max_hp]
	_hp_label.visible = true


func clear_hit_points() -> void:
	if _hp_label == null:
		return
	_hp_label.text = ""
	_hp_label.visible = false


func set_selected(on: bool) -> void:
	if _selection_ring == null:
		return
	_selection_ring.visible = on


func is_selected() -> bool:
	return _selection_ring != null and _selection_ring.visible


func follow_path(points: PackedVector2Array, start_tick: int, speed: float) -> void:
	if _walker == null:
		push_error("PlayerAvatar.follow_path: configure() was never called")
		return
	_walker.set_path(points, start_tick, speed)


func update_to_tick(tick: int) -> void:
	if _walker == null or not _walker.has_path():
		_set_walking(false)
		return

	var ground := _walker.position_at_tick(tick)
	position = Vector3(ground.x, ground_y, ground.y)
	_set_walking(not _walker.is_finished_at_tick(tick))

	if not face_travel_direction:
		return
	var heading := _walker.direction_at_tick(tick)
	if heading == Vector2.ZERO:
		return
	_desired_yaw = _yaw_facing(heading)


func is_idle_at_tick(tick: int) -> bool:
	if _walker == null:
		return true
	return _walker.is_finished_at_tick(tick)


func _process(delta: float) -> void:
	if clock != null and clock.is_anchored():
		update_to_tick(clock.estimated_tick())
	if face_travel_direction:
		_turn_toward_desired_yaw(delta)


func _set_walking(walking: bool) -> void:
	if walking:
		if _animation.current_animation != WALK_ANIM:
			_animation.play(WALK_ANIM)
		_animation.speed_scale = _walker.speed() / WALK_CLIP_SPEED
		return
	if _animation.current_animation != IDLE_ANIM:
		_animation.play(IDLE_ANIM)
	_animation.speed_scale = 1.0


func _turn_toward_desired_yaw(delta: float) -> void:
	rotation.y = rotate_toward(
		rotation.y, _desired_yaw, deg_to_rad(turn_degrees_per_second) * delta
	)


static func _yaw_facing(heading: Vector2) -> float:
	return atan2(-heading.x, -heading.y)
