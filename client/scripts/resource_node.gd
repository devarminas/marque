extends StaticBody3D

## One resource node's body. Instanced once per live node id by `session.gd`.
##
## The scene is [code]res://scenes/resource_node.tscn[/code]. How many nodes
## exist is genuine runtime information, so instancing it in script is the case
## CLAUDE.md allows. Trunk, foliage, collision, and materials are authored in
## the scene; this script only binds id/kind/state and swaps visibility.
##
## Collision layer 3 (mask value 4) is exclusive to resource nodes. Ground is
## layer 1, ground items layer 2. [code]ground_picker.gd[/code] casts one ray
## against all three so the nearest surface wins.
##
## Typed by [code]preload[/code], per NOTES.md, "Godot authoring traps".

const NodeKinds := preload("res://scripts/node_kinds.gd")

## Server node id, or 0 before [method configure].
var node_id := 0

## `node_spawn.kind`, held verbatim including unknown kinds.
var kind := ""

## `full` or `depleted`, or "" before [method configure].
var state := ""

@export var ground_y := 0.0
@export var trunk: MeshInstance3D
@export var foliage: MeshInstance3D
@export var known_trunk_material: StandardMaterial3D
@export var known_foliage_material: StandardMaterial3D
@export var unknown_material: StandardMaterial3D
@export var depleted_trunk_material: StandardMaterial3D


func configure(id: int, node_kind: String, node_state: String) -> void:
	if id <= 0:
		push_error("ResourceNode.configure: node ids start at 1, got %d" % id)
		return
	node_id = id
	kind = node_kind
	_apply_state(node_state)


func place_at(x: float, z: float) -> void:
	position = Vector3(x, ground_y, z)


func apply_state(node_state: String) -> void:
	_apply_state(node_state)


func is_kind_known() -> bool:
	return NodeKinds.is_known(kind)


func is_depleted() -> bool:
	return state == "depleted"


func drawn_color() -> Color:
	if trunk == null or trunk.material_override == null:
		return Color.BLACK
	var material := trunk.material_override as StandardMaterial3D
	if material == null:
		return Color.BLACK
	return material.albedo_color


func _apply_state(node_state: String) -> void:
	if node_state != "full" and node_state != "depleted":
		push_error(
			'ResourceNode: node %d got unknown state "%s"; keeping prior visual'
			% [node_id, node_state]
		)
		return
	state = node_state
	if trunk == null or foliage == null:
		push_error("ResourceNode: the scene did not assign trunk and foliage meshes")
		return

	var known := is_kind_known()
	if not known:
		push_warning(
			'ResourceNode: node %d has unknown kind "%s"; drawing it magenta' % [node_id, kind]
		)
		trunk.material_override = unknown_material
		foliage.material_override = unknown_material
		foliage.visible = state == "full"
		scale = Vector3.ONE if state == "full" else Vector3(0.7, 0.55, 0.7)
		return

	if state == "depleted":
		trunk.material_override = depleted_trunk_material
		foliage.visible = false
		scale = Vector3(0.7, 0.55, 0.7)
	else:
		trunk.material_override = known_trunk_material
		foliage.material_override = known_foliage_material
		foliage.visible = true
		scale = Vector3.ONE
