class_name NpcDummy
extends Node3D

const PolylineWalker := preload("res://scripts/polyline_walker.gd")
const TickClock := preload("res://scripts/tick_clock.gd")
const DummyMeterScript := preload("res://scripts/dummy_meter.gd")

const FactionFriendly := "friendly"
const FactionHostile := "hostile"
const FactionNeutral := "neutral"

const KindDummy := "dummy"
const KindQuestGiver := "quest_giver"
const KindImpQuestGiver := "imp_quest_giver"
const KindImp := "imp"

const IDLE_ANIM := "ual2/Idle_FoldArms"
const WALK_ANIM := "ual2/Walk_Carry"
const WALK_CLIP_SPEED := 0.65

var npc_id := 0
var kind := KindDummy
var faction := FactionHostile

var clock: TickClock = null

@export var ground_y := 0.0
@export var face_travel_direction := true
@export var turn_degrees_per_second := 540.0
@export var static_mesh := false

var _body_mesh: MeshInstance3D = null
var _meter: DummyMeterScript = null
var _last_hp := -1
var _last_max_hp := -1
var _walker: PolylineWalker = null
var _tick_ms := 0
var _desired_yaw := 0.0
var _animation: AnimationPlayer = null
var _missing_animation_reported := false

@onready var _selection_ring: MeshInstance3D = $SelectionRing
@onready var _hp_label: Label3D = $HpLabel
var _meter_label: Label3D = null


func _ready() -> void:
	_meter_label = get_node_or_null("MeterLabel") as Label3D
	var body := get_node_or_null("Body")
	if body is MeshInstance3D:
		_body_mesh = body as MeshInstance3D
	var missing := get_node_or_null("MissingBody") as MeshInstance3D
	if missing != null and get_node_or_null("Body/Armature/Skeleton3D") == null:
		missing.visible = true
	_animation = get_node_or_null("AnimationPlayer") as AnimationPlayer
	if _animation != null and _animation.has_animation(IDLE_ANIM):
		_animation.play(IDLE_ANIM)
	_apply_faction_color()
	if kind == KindDummy:
		_meter = DummyMeterScript.new()
		_configure_meter_label()


func _physics_process(_delta: float) -> void:
	if kind != KindDummy or _meter == null or _meter_label == null:
		return
	var rate := _meter.rate_per_sec()
	if rate <= 0.05:
		_meter_label.visible = false
		_meter_label.text = ""
		return
	_meter_label.visible = true
	if faction == FactionFriendly:
		_meter_label.text = "HPS %.0f" % rate
		_meter_label.modulate = Color(0.35, 0.95, 0.45, 1)
	else:
		_meter_label.text = "DPS %.0f" % rate
		_meter_label.modulate = Color(1, 0.55, 0.2, 1)


func configure(id: int, npc_kind: String, npc_faction: String) -> void:
	npc_id = id
	kind = npc_kind
	faction = npc_faction
	name = "Npc%d" % id
	_apply_faction_color()
	if kind == KindDummy and _meter == null:
		_meter = DummyMeterScript.new()
		_configure_meter_label()


func configure_motion(tick_ms: int) -> void:
	if tick_ms <= 0:
		push_error("NpcDummy.configure_motion: tick_ms must be > 0, got %d" % tick_ms)
		return
	_tick_ms = tick_ms
	_walker = PolylineWalker.new(tick_ms)


func place_at(x: float, z: float) -> void:
	position = Vector3(x, ground_y, z)
	if _tick_ms > 0:
		_walker = PolylineWalker.new(_tick_ms)


func follow_path(points: PackedVector2Array, start_tick: int, speed: float) -> void:
	if _walker == null:
		push_error("NpcDummy.follow_path: configure_motion() was never called")
		return
	_walker.set_path(points, start_tick, speed)


func has_path() -> bool:
	return _walker != null and _walker.has_path()


func is_walking() -> bool:
	if not has_path():
		return false
	if clock == null or not clock.is_anchored():
		return true
	return not _walker.is_finished_at_tick(clock.estimated_tick())


func current_anim_clip() -> String:
	if _animation == null:
		return "none"
	var clip := _animation.current_animation
	if clip.is_empty():
		return "none"
	return clip


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


func _process(delta: float) -> void:
	if clock != null and clock.is_anchored():
		update_to_tick(clock.estimated_tick())
	if face_travel_direction:
		_turn_toward_desired_yaw(delta)


func set_selected(on: bool) -> void:
	if _selection_ring == null:
		return
	_selection_ring.visible = on


func is_selected() -> bool:
	return _selection_ring != null and _selection_ring.visible


func set_hit_points(hp: int, max_hp: int) -> void:
	if _hp_label == null:
		return
	_hp_label.visible = true
	_hp_label.text = "%d/%d" % [hp, max_hp]
	if kind != KindDummy or _meter == null:
		return
	if _last_hp >= 0 and hp != _last_hp:
		_meter.observe_hp(hp, max_hp)
	_last_hp = hp
	_last_max_hp = max_hp


func observe_cast(ability_id: String) -> void:
	if kind != KindDummy or _meter == null:
		return
	_meter.observe_cast(ability_id)


func clear_hit_points() -> void:
	if _hp_label == null:
		return
	_hp_label.visible = false
	_hp_label.text = ""
	if _meter_label != null:
		_meter_label.visible = false
		_meter_label.text = ""
	if _meter != null:
		_meter.reset()
	_last_hp = -1
	_last_max_hp = -1


func _configure_meter_label() -> void:
	if _meter_label == null:
		return
	_meter_label.visible = false
	_meter_label.text = ""


func _apply_faction_color() -> void:
	if _body_mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if faction == FactionFriendly:
		mat.albedo_color = Color(0.25, 0.75, 0.35, 1)
	elif faction == FactionNeutral:
		mat.albedo_color = Color(0.35, 0.55, 0.9, 1)
	else:
		mat.albedo_color = Color(0.85, 0.25, 0.2, 1)
	_body_mesh.material_override = mat


func _set_walking(walking: bool) -> void:
	if _animation == null:
		if not static_mesh and not _missing_animation_reported:
			_missing_animation_reported = true
			push_error(
				"NpcDummy '%s' (kind=%s): mobile NPC lacks AnimationPlayer; walk/idle will no-op"
				% [name, kind]
			)
		return
	if walking:
		if _animation.has_animation(WALK_ANIM) and _animation.current_animation != WALK_ANIM:
			_animation.play(WALK_ANIM)
		if _animation.has_animation(WALK_ANIM) and _walker != null:
			_animation.speed_scale = _walker.speed() / WALK_CLIP_SPEED
		return
	if _animation.has_animation(IDLE_ANIM) and _animation.current_animation != IDLE_ANIM:
		_animation.play(IDLE_ANIM)
	_animation.speed_scale = 1.0


func _turn_toward_desired_yaw(delta: float) -> void:
	rotation.y = rotate_toward(
		rotation.y, _desired_yaw, deg_to_rad(turn_degrees_per_second) * delta
	)


static func _yaw_facing(heading: Vector2) -> float:
	return atan2(-heading.x, -heading.y)