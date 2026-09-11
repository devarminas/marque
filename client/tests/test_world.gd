extends Node


const POSITION_EPSILON := 0.001
const FOLLOW_FRAMES := 30

const CameraRigScript := preload("res://scripts/camera_rig.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")

@onready var _player: Node3D = $World/PlayerCharacter/Player
@onready var _remote_players: Node3D = $World/RemotePlayers
@onready var _rig: CameraRigScript = $World/PlayerCharacter/CameraRig
@onready var _camera: Camera3D = $World/PlayerCharacter/CameraRig/Camera3D
@onready var _picker: GroundPickerScript = $World/GroundPicker

var _failures: Array[String] = []
var _picker_signals: Array[String] = []
var _assertion_count := 0
var _finished := false


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return PackedStringArray(_failures)


func get_assertion_count() -> int:
	return _assertion_count


func _ready() -> void:
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
	await _test_a_left_click_on_bare_ground_emits_no_signal()
	_test_ray_at_sky_returns_no_hit()

	_finished = true


func _test_scene_contract() -> void:
	_check(_player != null, "Player placeholder exists")
	_check(_remote_players != null, "RemotePlayers container exists")
	_check(
		_remote_players != null and _remote_players.get_child_count() == 0,
		"RemotePlayers starts empty",
	)
	_check(_rig != null and _rig.camera == _camera, "CameraRig owns the Camera3D")
	_check(_picker != null and _picker.camera == _camera, "GroundPicker uses the same camera")
	var world_map := $World/WorldMap as Node3D
	_check(world_map != null, "main instances WorldMap as the play ground")
	var ground_mesh := null if world_map == null else world_map.get_node_or_null("Ground/Mesh") as MeshInstance3D
	_check(
		ground_mesh != null and ground_mesh.mesh is PlaneMesh,
		"WorldMap authors a Ground/Mesh PlaneMesh",
	)
	if ground_mesh != null and ground_mesh.mesh is PlaneMesh:
		var plane := ground_mesh.mesh as PlaneMesh
		_check(
			plane.size.is_equal_approx(Vector2(256.0, 256.0)),
			"WorldMap ground is 256 x 256, got %v" % plane.size,
		)


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

	_check(
		_rig.pitch_min_degrees > -90.0 and _rig.pitch_max_degrees < 0.0,
		"pitch limits keep the camera above the player and below the vertical",
	)

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


func _test_ground_pick_at_known_transform() -> void:
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


func _test_a_left_click_on_bare_ground_emits_no_signal() -> void:
	var viewport := _camera.get_viewport()
	var centre := viewport.get_visible_rect().size * 0.5

	var resolved := _picker.pick(centre)
	_check(
		resolved["target"] == GroundPickerScript.Target.GROUND,
		"the ray at screen centre meets bare ground, got target %d" % resolved["target"],
	)

	_picker.item_clicked.connect(_on_picker_signal.bind("item_clicked"))
	_picker.node_gather_clicked.connect(_on_picker_signal.bind("node_gather_clicked"))
	_picker.player_clicked.connect(_on_picker_signal.bind("player_clicked"))
	_picker.player_attack_clicked.connect(_on_picker_signal.bind("player_attack_clicked"))
	_picker_signals.clear()

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = centre
	viewport.push_input(press)
	await get_tree().process_frame

	_check(
		_picker_signals.is_empty(),
		"a left click on bare ground emits none of the picker's signals, got %s"
		% [_picker_signals],
	)


func _test_ray_at_sky_returns_no_hit() -> void:
	_camera.global_transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3(0.0, 5.0, 0.0)
	)
	var centre := _camera.get_viewport().get_visible_rect().size * 0.5
	var sky = _picker.pick_ground(centre)
	_check(sky == null, "a ray at the sky returns null, got %s" % [sky])


func _on_picker_signal(_body: Node3D, signal_name: String) -> void:
	_picker_signals.append(signal_name)


func _check(condition: bool, message: String) -> void:
	_assertion_count += 1
	if condition:
		print("  ok    " + message)
		return
	_failures.append(message)
	print("  FAIL  " + message)
