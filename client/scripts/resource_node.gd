extends StaticBody3D


const CharacterVisual := preload("res://scripts/character_visual.gd")
const NodeKinds := preload("res://scripts/node_kinds.gd")

enum Look { FULL, DEPLETED, MISSING }

var node_id := 0

var kind := ""

var state := ""

@export var ground_y := 0.0
@export var props: Node3D
@export var missing_visual: MeshInstance3D
@export var trunk_shape: CollisionShape3D
@export var canopy_shape: CollisionShape3D

var _look: Look = Look.FULL


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


func is_smelter() -> bool:
	return kind == NodeKinds.KIND_SMELTER


func is_gatherable() -> bool:
	return NodeKinds.is_gatherable(kind)


func showing() -> Look:
	return _look


func prop_name() -> String:
	return CharacterVisual.contract().prop_for(kind, state).get_file().get_basename()


func shown_visual() -> Node3D:
	if _look == Look.MISSING:
		return missing_visual
	return props.get_node_or_null(prop_name()) as Node3D


static func look_for(kind_known: bool, node_state: String) -> Look:
	if not kind_known:
		return Look.MISSING
	if node_state == "depleted":
		return Look.DEPLETED
	return Look.FULL


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
	if props == null:
		unassigned.append("props")
	if missing_visual == null:
		unassigned.append("missing_visual")
	if trunk_shape == null:
		unassigned.append("trunk_shape")
	if canopy_shape == null:
		unassigned.append("canopy_shape")
	if not unassigned.is_empty():
		push_error("ResourceNode: the scene did not assign %s" % ", ".join(unassigned))
		return

	_look = next
	var drawn := shown_visual()
	if drawn == null and next != Look.MISSING:
		push_error(
			'ResourceNode: node %d wants a "%s" prop that the scene does not author'
			% [node_id, prop_name()]
		)
	missing_visual.visible = next == Look.MISSING
	for child in props.get_children():
		var visual := child as Node3D
		if visual != null:
			visual.visible = visual == drawn

	canopy_shape.disabled = next != Look.FULL or kind != NodeKinds.KIND_TREE
