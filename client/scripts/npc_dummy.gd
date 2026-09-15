class_name NpcDummy
extends Node3D

const PolylineWalker := preload("res://scripts/polyline_walker.gd")
const TickClock := preload("res://scripts/tick_clock.gd")
const DummyMeterScript := preload("res://scripts/dummy_meter.gd")
const CharacterVisual := preload("res://scripts/character_visual.gd")

const FactionFriendly := "friendly"
const FactionHostile := "hostile"
const FactionNeutral := "neutral"

const KindDummy := "dummy"
const KindQuestGiver := "quest_giver"
const KindImpQuestGiver := "imp_quest_giver"
const KindImp := "imp"

const OVERHEAD_PROXIMITY := 12.0
const OVERHEAD_CLICK_LAYER := 4

var npc_id := 0
var kind := KindDummy
var faction := FactionHostile
var display_name := ""

var clock: TickClock = null

@export var ground_y := 0.0
@export var face_travel_direction := true
@export var turn_degrees_per_second := 540.0
@export var static_mesh := false

var _body_mesh: MeshInstance3D = null
var _meter: DummyMeterScript = null
var _last_hp := -1
var _last_max_hp := -1
var _has_hit_points := false
var _overhead_near := false
var _walker: PolylineWalker = null
var _tick_ms := 0
var _desired_yaw := 0.0
var _missing_visual_reported := false

@onready var _selection_ring: MeshInstance3D = $SelectionRing
@onready var _hp_label: Label3D = $HpLabel
@onready var _name_label: Label3D = $NameLabel
@onready var _overhead_click: StaticBody3D = $OverheadClick
var _meter_label: Label3D = null


func _ready() -> void:
	_meter_label = get_node_or_null("MeterLabel") as Label3D
	var body := get_node_or_null("Body")
	if body is MeshInstance3D:
		_body_mesh = body as MeshInstance3D
	var missing := get_node_or_null("MissingBody") as MeshInstance3D
	if missing != null and visual() != null and get_node_or_null("Body/Rig/Skeleton3D") == null:
		missing.visible = true
	_apply_faction_color()
	if kind == KindDummy:
		_meter = DummyMeterScript.new()
		_configure_meter_label()
	_apply_overhead_visibility()


func _physics_process(_delta: float) -> void:
	if kind != KindDummy or _meter == null or _meter_label == null:
		return
	if not _overhead_chrome_allowed():
		_meter_label.visible = false
		_meter_label.text = ""
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


func configure(id: int, npc_kind: String, npc_faction: String, npc_name: String) -> void:
	npc_id = id
	kind = npc_kind
	faction = npc_faction
	display_name = npc_name
	name = "Npc%d" % id
	_apply_faction_color()
	if kind == KindDummy and _meter == null:
		_meter = DummyMeterScript.new()
		_configure_meter_label()
	_apply_overhead_visibility()


func is_talkable() -> bool:
	return kind == KindQuestGiver or kind == KindImpQuestGiver


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
	var animation := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if animation == null:
		return "none"
	var clip := animation.current_animation
	if clip.is_empty():
		return "none"
	return clip


func visual() -> CharacterVisual:
	return get_node_or_null("Visual") as CharacterVisual


func swing(weapon: String) -> void:
	var character := visual()
	if character == null:
		push_error("NpcDummy '%s' (kind=%s): a swing arrived for an NPC with no CharacterVisual" % [name, kind])
		return
	character.swing(weapon, _tick_ms)


func update_to_tick(tick: int) -> void:
	if _walker == null or not _walker.has_path():
		_locomote(0.0)
		return

	var ground := _walker.position_at_tick(tick)
	position = Vector3(ground.x, ground_y, ground.y)
	_locomote(0.0 if _walker.is_finished_at_tick(tick) else _walker.speed())

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
	_has_hit_points = true
	if _hp_label != null:
		_hp_label.text = "%d/%d" % [hp, max_hp]
	_apply_overhead_visibility()
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
	_has_hit_points = false
	_last_hp = -1
	_last_max_hp = -1
	if _hp_label != null:
		_hp_label.text = ""
	if _meter_label != null:
		_meter_label.visible = false
		_meter_label.text = ""
	if _meter != null:
		_meter.reset()
	_apply_overhead_visibility()


func refresh_overhead_proximity(local_xz: Vector2) -> void:
	var dist := Vector2(position.x, position.z).distance_to(local_xz)
	_overhead_near = dist <= OVERHEAD_PROXIMITY
	_apply_overhead_visibility()


func overhead_visible() -> bool:
	return _hp_label != null and _hp_label.visible


func _configure_meter_label() -> void:
	if _meter_label == null:
		return
	_meter_label.visible = false
	_meter_label.text = ""


func _overhead_chrome_allowed() -> bool:
	if not _has_hit_points:
		return false
	if faction != FactionHostile:
		return true
	return _overhead_near


func _apply_overhead_visibility() -> void:
	var show := _overhead_chrome_allowed()
	if _hp_label != null:
		_hp_label.visible = show
	if _name_label != null:
		if show and faction == FactionHostile and not display_name.is_empty():
			_name_label.visible = true
			_name_label.text = display_name
		else:
			_name_label.visible = false
			_name_label.text = ""
	if _overhead_click != null:
		_overhead_click.collision_layer = OVERHEAD_CLICK_LAYER if show and faction == FactionHostile else 0
	if not show and _meter_label != null:
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


func _locomote(ground_speed: float) -> void:
	var character := visual()
	if character == null:
		if not static_mesh and not _missing_visual_reported:
			_missing_visual_reported = true
			push_error(
				"NpcDummy '%s' (kind=%s): mobile NPC lacks a CharacterVisual; walk and idle will no-op"
				% [name, kind]
			)
		return
	character.locomote(ground_speed)


func _turn_toward_desired_yaw(delta: float) -> void:
	rotation.y = rotate_toward(
		rotation.y, _desired_yaw, deg_to_rad(turn_degrees_per_second) * delta
	)


static func _yaw_facing(heading: Vector2) -> float:
	return atan2(-heading.x, -heading.y)