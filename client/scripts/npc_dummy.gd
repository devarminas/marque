class_name NpcDummy
extends Node3D

const FactionFriendly := "friendly"
const FactionHostile := "hostile"
const FactionNeutral := "neutral"

const KindDummy := "dummy"
const KindQuestGiver := "quest_giver"
const KindImp := "imp"

const IDLE_ANIM := "ual2/Idle_FoldArms"

var npc_id := 0
var kind := KindDummy
var faction := FactionHostile

var _body_mesh: MeshInstance3D = null

@onready var _selection_ring: MeshInstance3D = $SelectionRing
@onready var _hp_label: Label3D = $HpLabel


func _ready() -> void:
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


func configure(id: int, npc_kind: String, npc_faction: String) -> void:
	npc_id = id
	kind = npc_kind
	faction = npc_faction
	name = "Npc%d" % id
	_apply_faction_color()


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


func clear_hit_points() -> void:
	if _hp_label == null:
		return
	_hp_label.visible = false
	_hp_label.text = ""


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
