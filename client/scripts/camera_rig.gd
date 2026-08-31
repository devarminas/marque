class_name CameraRig
extends Node3D

## Orbiting third-person camera rig. Pure client presentation.
##
## The rig is a pivot that sits on [member target]; the camera is its child,
## offset backwards along the pivot's local +Z. Orbiting rotates the pivot,
## zooming slides the camera along that axis.
##
## Two invariants this file exists to keep:
##
## 1. The rig reads [member target] and never writes to it. The camera follows
##    the player; it never drives the player.
## 2. Nothing here reaches the server. The protocol has no facing and no view
##    direction, and it never will (NOTES.md, "Camera").
##
## Yaw, pitch and distance are stored as plain floats and the transform is
## rebuilt from them. Reading Euler angles back out of a [Basis] fights the
## wrap at +-180 degrees and makes the pitch clamp unreliable.
##
## The rig is authored in [code]main.tscn[/code], including its default framing.
## Every number below is a placeholder chosen to be usable, not good; they are
## exported so a human can tune them in the inspector (FOLLOW-UPS.md).

## The node the rig follows. Read-only to this script.
@export var target: Node3D
## The camera this rig owns. Its local position is overwritten on every zoom.
@export var camera: Camera3D

@export_group("Feel")
## Degrees of rotation per pixel of mouse travel while orbiting.
@export var orbit_degrees_per_pixel := 0.35
## World units the camera moves per wheel notch.
@export var zoom_step := 1.5
## How hard the rig chases the target. Higher is snappier; 0 pins it in place.
@export var follow_damping := 12.0

@export_group("Limits")
## Most downward pitch. Keeps the camera from passing through the ground.
@export var pitch_min_degrees := -80.0
## Most level pitch. Keeps the camera above the horizon, never under it.
@export var pitch_max_degrees := -12.0
@export var distance_min := 4.0
@export var distance_max := 32.0

@export_group("Default framing")
## Authoritative starting framing. The node transforms in [code]main.tscn[/code]
## are authored to match these so the editor viewport shows what the game shows.
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
	# Exponential smoothing, so the feel does not change with framerate.
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


## Orbits the rig. Both deltas are in mouse pixels and are scaled by
## [member orbit_degrees_per_pixel]. Yaw wraps into [code][0, 360)[/code];
## pitch is clamped and stays clamped no matter how far it is pushed.
func orbit_by(yaw_pixels: float, pitch_pixels: float) -> void:
	_yaw_degrees = fposmod(_yaw_degrees - yaw_pixels * orbit_degrees_per_pixel, 360.0)
	_pitch_degrees = clampf(
		_pitch_degrees - pitch_pixels * orbit_degrees_per_pixel,
		pitch_min_degrees,
		pitch_max_degrees,
	)
	_apply()


## Moves the camera along its local Z. Positive [param steps] pulls back.
## The result is clamped to [member distance_min] .. [member distance_max].
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
	# Euler order YXZ: yaw about world Y, then pitch about the rig's own X.
	transform.basis = Basis.from_euler(
		Vector3(deg_to_rad(_pitch_degrees), deg_to_rad(_yaw_degrees), 0.0)
	)
	if camera != null:
		camera.position = Vector3(0.0, 0.0, _distance)
