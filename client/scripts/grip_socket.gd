extends Node3D


@export var bone_name := ""

@export var body_path := NodePath()

@export var skeleton_path := NodePath()

var _body: Node3D = null
var _skeleton: Skeleton3D = null
var _bone := -1


func _ready() -> void:
	_body = get_node_or_null(body_path) as Node3D
	if _body == null:
		push_error(
			"GripSocket %s: body_path '%s' does not reach a Node3D" % [name, body_path]
		)
		return
	_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	if _skeleton == null:
		push_error(
			"GripSocket %s: skeleton_path '%s' does not reach a Skeleton3D" % [name, skeleton_path]
		)
		return
	_bone = _skeleton.find_bone(bone_name)
	if _bone < 0:
		push_error('GripSocket %s: the rig carries no bone named "%s"' % [name, bone_name])
		return
	_skeleton.skeleton_updated.connect(_follow_bone)
	_follow_bone()


func show_kind(kind: String) -> void:
	var matched := false
	for child in get_children():
		var mounted := child as Node3D
		if mounted == null:
			continue
		mounted.visible = String(mounted.name) == kind
		matched = matched or mounted.visible
	if not kind.is_empty() and not matched:
		push_warning('GripSocket %s: no authored mesh is named "%s"' % [name, kind])


func shown_kind() -> String:
	for child in get_children():
		var mounted := child as Node3D
		if mounted != null and mounted.visible:
			return String(mounted.name)
	return ""


func _follow_bone() -> void:
	if not _body.is_inside_tree() or not _skeleton.is_inside_tree():
		return
	var body_to_skeleton := _body.global_transform.affine_inverse() * _skeleton.global_transform
	transform = body_to_skeleton * _skeleton.get_bone_global_pose(_bone)
