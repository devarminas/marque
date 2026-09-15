extends Node3D


const TickClock := preload("res://scripts/tick_clock.gd")
const CharacterVisual := preload("res://scripts/character_visual.gd")
const SteerIntegrate := preload("res://scripts/steer_integrate.gd")

var player_id := 0

var clock: TickClock = null

@export var ground_y := 0.0

@export var face_travel_direction := true

# Linear ARM-51.
@export var turn_degrees_per_second := 540.0

var _desired_yaw := 0.0
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


func present_at(x: float, z: float, walking: bool, height: float = 0.0) -> void:
	var prior := Vector2(position.x, position.z)
	position = Vector3(x, ground_y + height, z)
	visual().locomote(SteerIntegrate.WALK_SPEED if walking else 0.0)
	if not face_travel_direction or not walking:
		return
	var delta := Vector2(x - prior.x, z - prior.y)
	if delta.length_squared() < 1e-8:
		return
	_desired_yaw = _yaw_facing(delta)


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
	if face_travel_direction:
		_turn_toward_desired_yaw(delta)


func _turn_toward_desired_yaw(delta: float) -> void:
	rotation.y = rotate_toward(
		rotation.y, _desired_yaw, deg_to_rad(turn_degrees_per_second) * delta
	)


static func _yaw_facing(heading: Vector2) -> float:
	return atan2(-heading.x, -heading.y)
