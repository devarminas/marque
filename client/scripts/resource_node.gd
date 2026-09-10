extends StaticBody3D


const NodeKinds := preload("res://scripts/node_kinds.gd")

enum Look { TREE, STUMP, MISSING }

var node_id := 0

var kind := ""

var state := ""

@export var ground_y := 0.0
@export var tree_visual: Node3D
@export var stump_visual: MeshInstance3D
@export var rock_visual: Node3D
@export var rock_depleted_visual: Node3D
@export var missing_visual: MeshInstance3D
@export var trunk_shape: CollisionShape3D
@export var canopy_shape: CollisionShape3D

var _look: Look = Look.TREE


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


func is_rock() -> bool:
	return kind == NodeKinds.KIND_ROCK


func showing() -> Look:
	return _look


static func look_for(kind_known: bool, node_state: String) -> Look:
	if not kind_known:
		return Look.MISSING
	if node_state == "depleted":
		return Look.STUMP
	return Look.TREE


func _apply_state(node_state: String) -> void:
	if node_state != "full" and node_state != "depleted":
		push_error(
			'ResourceNode: node %d got unknown state "%s"; keeping prior visual'
			% [node_id, node_state]
		)
		return
	state = node_state
	var known := is_kind_known()
	if not known:
		push_warning(
			'ResourceNode: node %d has unknown kind "%s"; drawing it magenta' % [node_id, kind]
		)
	_show(look_for(known, state))


func _show(next: Look) -> void:
	var unassigned := PackedStringArray()
	if tree_visual == null:
		unassigned.append("tree_visual")
	if stump_visual == null:
		unassigned.append("stump_visual")
	if rock_visual == null:
		unassigned.append("rock_visual")
	if rock_depleted_visual == null:
		unassigned.append("rock_depleted_visual")
	if missing_visual == null:
		unassigned.append("missing_visual")
	if trunk_shape == null:
		unassigned.append("trunk_shape")
	if canopy_shape == null:
		unassigned.append("canopy_shape")
	if not unassigned.is_empty():
		push_error("ResourceNode: the scene did not assign %s" % ", ".join(unassigned))
		return

	var rock := is_rock()
	var full := next == Look.TREE
	var depleted := next == Look.STUMP
	var missing := next == Look.MISSING

	tree_visual.visible = full and not rock
	stump_visual.visible = depleted and not rock
	rock_visual.visible = full and rock
	rock_depleted_visual.visible = depleted and rock
	missing_visual.visible = missing

	canopy_shape.disabled = not full or rock
	_look = next
