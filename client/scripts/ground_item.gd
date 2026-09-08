extends StaticBody3D


const KIND_SCENES := {
	"lumberjack_axe": preload("res://scenes/ground_item_lumberjack_axe.tscn"),
}

const ItemKinds := preload("res://scripts/item_kinds.gd")

var item_id := 0

var kind := ""

@export var ground_y := 0.0

@export var mesh: MeshInstance3D

@export var known_material: StandardMaterial3D

@export var unknown_material: StandardMaterial3D

var _model: Node3D = null


func _ready() -> void:
	if kind == "" or not KIND_SCENES.has(kind):
		return
	var scene: PackedScene = KIND_SCENES[kind]
	var model := scene.instantiate() as Node3D
	if model == null:
		push_error("GroundItem: the art scene for kind \"%s\" did not instantiate" % kind)
		return
	model.name = "Model"
	add_child(model)
	mesh.visible = false
	_model = model


func configure(id: int, item_kind: String) -> void:
	if id <= 0:
		push_error("GroundItem.configure: item ids start at 1, got %d" % id)
		return
	item_id = id
	kind = item_kind

	if mesh == null:
		push_error("GroundItem.configure: the scene did not assign a mesh node")
		return
	var material := known_material if is_kind_known() else unknown_material
	if material == null:
		push_error("GroundItem.configure: the scene did not assign both materials")
		return
	if not is_kind_known():
		push_warning(
			'GroundItem: item %d has unknown kind "%s"; drawing it magenta' % [id, item_kind]
		)
	mesh.material_override = material


func place_at(x: float, z: float) -> void:
	position = Vector3(x, ground_y, z)


func is_kind_known() -> bool:
	return ItemKinds.is_known(kind)


func display_color() -> Color:
	if mesh == null:
		return Color(0, 0, 0, 0)
	var material := mesh.material_override as StandardMaterial3D
	if material == null:
		return Color(0, 0, 0, 0)
	return material.albedo_color


func has_model() -> bool:
	return _model != null


func local_bounds() -> AABB:
	if _model != null:
		var bounds := AABB()
		var found := false
		for node in _model.find_children("*", "MeshInstance3D", true, true):
			var mesh_instance := node as MeshInstance3D
			if mesh_instance.mesh == null:
				continue
			var local := mesh_instance.transform
			var up := mesh_instance.get_parent()
			while up != _model and up is Node3D:
				local = (up as Node3D).transform * local
				up = up.get_parent()
			var mesh_bounds := local * mesh_instance.mesh.get_aabb()
			bounds = mesh_bounds if not found else bounds.merge(mesh_bounds)
			found = true
		if found:
			return _model.transform * bounds
		push_error('GroundItem: kind "%s" has a model with no meshes; falling back to the box' % kind)
	if mesh == null:
		return AABB()
	return mesh.transform * mesh.get_aabb()
