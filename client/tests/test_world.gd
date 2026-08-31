extends Node

## Headless tests for the M0c camera rig and ground raycast.
##
## Everything here is logic, physics, and signals, which all run headless. The
## visual check is a separate windowed run (see [code]scripts/main.gd[/code]).
##
## The world under test is [code]main.tscn[/code], instanced as a child in
## [code]test_world.tscn[/code] rather than assembled here, so the tests exercise
## the same authored scene the game ships.

## Ground pick tolerance in world units. The expectations are exact reals; this
## only absorbs float32 transform round-tripping through the physics server.
const POSITION_EPSILON := 0.001
## Frames to let the follow damping act before checking that it converged.
const FOLLOW_FRAMES := 30

# Typed by preloaded script rather than by the `class_name` global. Global class
# names resolve through a cache that only the editor scan writes, and this suite
# has to run from a fresh clone that has never opened the editor.
const CameraRigScript := preload("res://scripts/camera_rig.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")

@onready var _player: Node3D = $World/Player
@onready var _remote_players: Node3D = $World/RemotePlayers
@onready var _rig: CameraRigScript = $World/CameraRig
@onready var _camera: Camera3D = $World/CameraRig/Camera3D
@onready var _picker: GroundPickerScript = $World/GroundPicker

var _failures: Array[String] = []
var _clicked_coordinates: Array[Vector2] = []


func _ready() -> void:
	# A ray query before the physics space has stepped finds nothing, and the
	# failure is indistinguishable from a broken raycast.
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("== scene contract ==")
	_test_scene_contract()
	print("== camera follow ==")
	await _test_follow_reads_target_without_writing()
	print("== pitch clamp ==")
	_test_pitch_clamp_holds_at_both_ends()
	print("== zoom clamp ==")
	_test_zoom_clamp_holds_at_both_ends()
	print("== ground pick ==")
	_test_ground_pick_at_known_transform()
	await _test_left_click_emits_ground_clicked()
	_test_ray_at_sky_returns_no_hit()

	if _failures.is_empty():
		print("PASS: all assertions held")
		get_tree().quit(0)
		return
	printerr("FAIL: %d assertion(s) failed" % _failures.size())
	for failure in _failures:
		printerr("  - " + failure)
	get_tree().quit(1)


## The nodes later units attach to must exist and must be authored, not built.
func _test_scene_contract() -> void:
	_check(_player != null, "Player placeholder exists")
	_check(_remote_players != null, "RemotePlayers container exists")
	_check(
		_remote_players != null and _remote_players.get_child_count() == 0,
		"RemotePlayers starts empty",
	)
	_check(_rig != null and _rig.camera == _camera, "CameraRig owns the Camera3D")
	_check(_picker != null and _picker.camera == _camera, "GroundPicker uses the same camera")


## The rig follows the target and never writes to it (NOTES.md, "Camera").
func _test_follow_reads_target_without_writing() -> void:
	var destination := Vector3(7.0, 0.0, -3.0)
	_player.global_position = destination
	var distance_before := _rig.global_position.distance_to(destination)

	for _frame in FOLLOW_FRAMES:
		await get_tree().process_frame

	_check(
		_player.global_position.is_equal_approx(destination),
		"rig never writes to its target (target still at %v)" % _player.global_position,
	)
	_check(
		_rig.global_position.distance_to(destination) < distance_before,
		"rig closed distance to the target (%f -> %f)"
		% [distance_before, _rig.global_position.distance_to(destination)],
	)


func _test_pitch_clamp_holds_at_both_ends() -> void:
	# Push far past the limit in both directions; a clamp that only survives
	# small inputs is not a clamp.
	_rig.orbit_by(0.0, -1.0e6)
	var pitch_up := _rig.get_pitch_degrees()
	_check(
		pitch_up <= _rig.pitch_max_degrees and pitch_up >= _rig.pitch_min_degrees,
		"pitch stays in [%f, %f] after a huge upward drag (got %f)"
		% [_rig.pitch_min_degrees, _rig.pitch_max_degrees, pitch_up],
	)
	_check(
		is_equal_approx(pitch_up, _rig.pitch_max_degrees),
		"pitch pins to pitch_max_degrees (%f) going up, got %f"
		% [_rig.pitch_max_degrees, pitch_up],
	)

	_rig.orbit_by(0.0, 1.0e6)
	var pitch_down := _rig.get_pitch_degrees()
	_check(
		pitch_down <= _rig.pitch_max_degrees and pitch_down >= _rig.pitch_min_degrees,
		"pitch stays in [%f, %f] after a huge downward drag (got %f)"
		% [_rig.pitch_min_degrees, _rig.pitch_max_degrees, pitch_down],
	)
	_check(
		is_equal_approx(pitch_down, _rig.pitch_min_degrees),
		"pitch pins to pitch_min_degrees (%f) going down, got %f"
		% [_rig.pitch_min_degrees, pitch_down],
	)

	# The clamp exists so the camera cannot pass under the ground or flip over
	# the top. Both limits must keep it looking down at the world.
	_check(
		_rig.pitch_min_degrees > -90.0 and _rig.pitch_max_degrees < 0.0,
		"pitch limits keep the camera above the player and below the vertical",
	)

	# Yaw is unclamped by design, but must not run away.
	_rig.orbit_by(1.0e6, 0.0)
	var yaw := _rig.get_yaw_degrees()
	_check(yaw >= 0.0 and yaw < 360.0, "yaw wraps into [0, 360), got %f" % yaw)


func _test_zoom_clamp_holds_at_both_ends() -> void:
	_rig.zoom_by(-1.0e6)
	var near := _rig.get_distance()
	_check(
		near >= _rig.distance_min and near <= _rig.distance_max,
		"distance stays in [%f, %f] after zooming all the way in (got %f)"
		% [_rig.distance_min, _rig.distance_max, near],
	)
	_check(
		is_equal_approx(near, _rig.distance_min),
		"distance pins to distance_min (%f), got %f" % [_rig.distance_min, near],
	)
	_check(
		is_equal_approx(_camera.position.z, near),
		"camera local Z tracks the clamped distance (%f vs %f)" % [_camera.position.z, near],
	)

	_rig.zoom_by(1.0e6)
	var far := _rig.get_distance()
	_check(
		far >= _rig.distance_min and far <= _rig.distance_max,
		"distance stays in [%f, %f] after zooming all the way out (got %f)"
		% [_rig.distance_min, _rig.distance_max, far],
	)
	_check(
		is_equal_approx(far, _rig.distance_max),
		"distance pins to distance_max (%f), got %f" % [_rig.distance_max, far],
	)
	_check(
		is_equal_approx(_camera.position.z, far),
		"camera local Z tracks the clamped distance (%f vs %f)" % [_camera.position.z, far],
	)


## One camera transform and one cursor position, worked out by hand.
##
## The camera sits 20m above (x=5, z=8) looking straight down. Its basis is
## Rx(-90 deg), so screen-right is world +X and screen-up is world -Z.
##
## With keep_aspect = KEEP_HEIGHT the vertical half-angle is fov/2 and pixels
## are square, so a cursor offset of d pixels from centre tilts the ray by
## tan(fov/2) * d / (height/2) per unit of depth. At fov = 60 and d = height/4
## that factor is 0.5 * tan(30 deg) = 0.288675135.
##
## Looking straight down from y = 20 the ray reaches the ground (y = 0) after
## exactly 20 units of depth, so the offsets on the ground are 20 * 0.288675135
## = 5.77350269 in +X (screen right) and +Z (screen down).
func _test_ground_pick_at_known_transform() -> void:
	# Detach the target first: the rig's follow would otherwise drag the camera
	# out from under the transform this test sets.
	_rig.target = null
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.fov = 60.0
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3(5.0, 20.0, 8.0)
	)

	var viewport_size := _camera.get_viewport().get_visible_rect().size
	var centre := viewport_size * 0.5

	var straight_down = _picker.pick_ground(centre)
	_check(straight_down != null, "centre-screen ray hits the ground")
	if straight_down != null:
		var hit: Vector2 = straight_down
		_check(
			absf(hit.x - 5.0) < POSITION_EPSILON and absf(hit.y - 8.0) < POSITION_EPSILON,
			"centre-screen ray lands directly below the camera at (5, 8), got (%f, %f)"
			% [hit.x, hit.y],
		)

	var cursor := centre + Vector2(viewport_size.y * 0.25, viewport_size.y * 0.25)
	var offset = _picker.pick_ground(cursor)
	_check(offset != null, "off-centre ray hits the ground")
	if offset != null:
		var hit: Vector2 = offset
		_check(
			absf(hit.x - 10.7735027) < POSITION_EPSILON,
			"off-centre ray x is 10.7735027, got %f" % hit.x,
		)
		_check(
			absf(hit.y - 13.7735027) < POSITION_EPSILON,
			"off-centre ray z is 13.7735027, got %f" % hit.y,
		)


## The seam M0d attaches to: a left click produces the signal, carrying the same
## coordinate pick_ground() computes.
func _test_left_click_emits_ground_clicked() -> void:
	_picker.ground_clicked.connect(_on_ground_clicked)
	_clicked_coordinates.clear()

	var viewport := _camera.get_viewport()
	var centre := viewport.get_visible_rect().size * 0.5

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = centre
	viewport.push_input(press)
	await get_tree().process_frame

	_picker.ground_clicked.disconnect(_on_ground_clicked)
	_check(
		_clicked_coordinates.size() == 1,
		"one left click emits ground_clicked once (got %d)" % _clicked_coordinates.size(),
	)
	if _clicked_coordinates.size() == 1:
		var coordinate := _clicked_coordinates[0]
		_check(
			absf(coordinate.x - 5.0) < POSITION_EPSILON
			and absf(coordinate.y - 8.0) < POSITION_EPSILON,
			"ground_clicked carries (5, 8), got (%f, %f)" % [coordinate.x, coordinate.y],
		)


## A ray with no ground under it must report a miss, not a coordinate.
func _test_ray_at_sky_returns_no_hit() -> void:
	# Rx(+90): the camera looks straight up from above the ground box, so the
	# ray leaves the world and meets nothing.
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3(0.0, 5.0, 0.0)
	)
	var centre := _camera.get_viewport().get_visible_rect().size * 0.5
	var sky = _picker.pick_ground(centre)
	_check(sky == null, "a ray at the sky returns null, got %s" % [sky])


func _on_ground_clicked(x: float, z: float) -> void:
	_clicked_coordinates.append(Vector2(x, z))


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok    " + message)
		return
	_failures.append(message)
	print("  FAIL  " + message)
