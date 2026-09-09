class_name NpcDummy
extends Node3D

const FactionFriendly := "friendly"
const FactionHostile := "hostile"
const FactionNeutral := "neutral"

const KindDummy := "dummy"
const KindQuestGiver := "quest_giver"
const KindImpQuestGiver := "imp_quest_giver"
const KindImp := "imp"

const IDLE_ANIM := "ual2/Idle_FoldArms"
const DummyMeterScript := preload("res://scripts/dummy_meter.gd")

var npc_id := 0
var kind := KindDummy
var faction := FactionHostile

var _body_mesh: MeshInstance3D = null
var _meter: DummyMeterScript = null
var _last_hp := -1
var _last_max_hp := -1

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
	var anim := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if anim != null and anim.has_animation(IDLE_ANIM):
		anim.play(IDLE_ANIM)
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


func place_at(x: float, z: float) -> void:
	position = Vector3(x, 0.0, z)


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