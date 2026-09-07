class_name CameraRig
extends Node3D


@export var target: Node3D
@export var camera: Camera3D

@export_group("Feel")
# Linear ARM-12.
@export var orbit_degrees_per_pixel := 0.35
@export var zoom_step := 1.5
@export var follow_damping := 12.0

@export_group("Limits")
@export var pitch_min_degrees := -80.0
@export var pitch_max_degrees := -12.0
@export var distance_min := 4.0
@export var distance_max := 32.0

@export_group("Default framing")
@export var default_yaw_degrees := 30.0
@export var default_pitch_degrees := -35.0
@export var default_distance := 14.0

var _yaw_degrees := 0.0
var _pitch_degrees := 0.0
var _distance := 0.0
var _orbiting := false


func _ready() -> void:
	_yaw_degrees = fposmod(default_yaw_degrees, 360.0)
	_pitch_degrees = clampf(default_pitch_degrees, pitch_min_degrees, pitch_max_degrees)
	_distance = clampf(default_distance, distance_min, distance_max)
	if target != null:
		global_position = target.global_position
	_apply()


func _process(delta: float) -> void:
	if target == null:
		return
	var weight := 1.0 - exp(-follow_damping * delta)
	global_position = global_position.lerp(target.global_position, weight)


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null:
		match button.button_index:
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_orbiting = button.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					zoom_by(-1.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					zoom_by(1.0)
		return

	var motion := event as InputEventMouseMotion
	if motion != null and _orbiting:
		orbit_by(motion.relative.x, motion.relative.y)


func orbit_by(yaw_pixels: float, pitch_pixels: float) -> void:
	_yaw_degrees = fposmod(_yaw_degrees - yaw_pixels * orbit_degrees_per_pixel, 360.0)
	_pitch_degrees = clampf(
		_pitch_degrees - pitch_pixels * orbit_degrees_per_pixel,
		pitch_min_degrees,
		pitch_max_degrees,
	)
	_apply()


func zoom_by(steps: float) -> void:
	_distance = clampf(_distance + steps * zoom_step, distance_min, distance_max)
	_apply()


func get_yaw_degrees() -> float:
	return _yaw_degrees


func get_pitch_degrees() -> float:
	return _pitch_degrees


func get_distance() -> float:
	return _distance


func _apply() -> void:
	transform.basis = Basis.from_euler(
		Vector3(deg_to_rad(_pitch_degrees), deg_to_rad(_yaw_degrees), 0.0)
	)
	if camera != null:
		camera.position = Vector3(0.0, 0.0, _distance)
