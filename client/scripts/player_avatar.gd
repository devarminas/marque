extends Node3D


const TickClock := preload("res://scripts/tick_clock.gd")
const CharacterVisual := preload("res://scripts/character_visual.gd")
const SteerIntegrate := preload("res://scripts/steer_integrate.gd")
const Facing := preload("res://scripts/facing.gd")

var player_id := 0

var clock: TickClock = null

@export var ground_y := 0.0

@export var face_travel_direction := true

# Linear ARM-51.
@export var turn_degrees_per_second := 540.0
@export var face_target_degrees_per_second := 360.0

var _desired_yaw := 0.0
var _target_yaw := 0.0
var _has_face_target := false
var _walking := false
var _tick_ms := 0

@onready var _hp_label: Label3D = $HpLabel
@onready var _selection_ring: MeshInstance3D = $SelectionRing
@onready var _missing_body: MeshInstance3D = $MissingBody


func _ready() -> void:
	if get_node_or_null("Body/Rig/Skeleton3D") == null:
		push_error(
			"PlayerAvatar: the prototype humanoid body did not instance under"
			+ " Body/Rig/Skeleton3D; drawing it magenta"
		)
		_missing_body.visible = true


func apply_equipment(slot_names: PackedStringArray, slot_kinds: PackedStringArray) -> void:
	visual().wear(slot_names, slot_kinds)


func swing(weapon: String) -> void:
	visual().swing(weapon, _tick_ms)


func cast_phase(phase: String, ability: String) -> void:
	visual().cast_phase(phase, ability)


func visual() -> CharacterVisual:
	return $Visual as CharacterVisual


func configure(id: int, tick_ms: int = 0) -> void:
	if id <= 0:
		push_error("PlayerAvatar.configure: player ids start at 1, got %d" % id)
		return
	player_id = id
	_tick_ms = tick_ms


func teleport_to(x: float, z: float) -> void:
	present_at(x, z, false)


func present_at(
	x: float, z: float, walking: bool, height: float = 0.0, ground_height: float = 0.0
) -> void:
	var prior := Vector2(position.x, position.z)
	position = Vector3(x, ground_y + height, z)
	visual().locomote(SteerIntegrate.WALK_SPEED if walking else 0.0)
	visual().elevate(height - ground_height)
	_walking = walking
	if walking:
		clear_face_target()
	if not face_travel_direction or not walking:
		return
	var delta := Vector2(x - prior.x, z - prior.y)
	if delta.length_squared() < 1e-8:
		return
	_desired_yaw = Facing.yaw_facing(delta)


func face_target(position_world: Vector3) -> void:
	if not face_travel_direction:
		return
	var direction := Vector2(position_world.x - global_position.x, position_world.z - global_position.z)
	if direction.length_squared() < 1.0e-8:
		return
	_target_yaw = Facing.yaw_facing(direction)
	_has_face_target = true


func clear_face_target() -> void:
	_has_face_target = false


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


func _process(delta: float) -> void:
	if not face_travel_direction:
		return
	if _walking:
		rotation.y = Facing.turn_toward(rotation.y, _desired_yaw, turn_degrees_per_second, delta)
	elif _has_face_target:
		rotation.y = Facing.turn_toward(rotation.y, _target_yaw, face_target_degrees_per_second, delta)
