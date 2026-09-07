class_name GroundPicker
extends Node

signal item_clicked(item: Node3D)

signal node_gather_clicked(resource_node: Node3D)

signal player_clicked(avatar: Node3D)

signal player_attack_clicked(avatar: Node3D)

enum Target {
	NOTHING,
	GROUND,
	ITEM,
	NODE,
	PLAYER,
}

const GroundItemScript := preload("res://scripts/ground_item.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")

@export var camera: Camera3D
@export var ray_length := 4096.0
@export_flags_3d_physics var ground_collision_mask := 1
@export_flags_3d_physics var item_collision_mask := 2
@export_flags_3d_physics var player_collision_mask := 4
@export_flags_3d_physics var node_collision_mask := 8


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	if button.button_index == MOUSE_BUTTON_RIGHT:
		var context_pick := pick(button.position)
		match context_pick["target"]:
			Target.NODE:
				node_gather_clicked.emit(context_pick["node"])
			Target.PLAYER:
				player_attack_clicked.emit(context_pick["player"])
			_:
				pass
		return
	if button.button_index != MOUSE_BUTTON_LEFT:
		return
	var picked := pick(button.position)
	match picked["target"]:
		Target.ITEM:
			item_clicked.emit(picked["item"])
		Target.PLAYER:
			player_clicked.emit(picked["player"])
		_:
			pass


func pick(screen_position: Vector2) -> Dictionary:
	var miss := {
		"target": Target.NOTHING,
		"ground": Vector2.ZERO,
		"item": null,
		"node": null,
		"player": null,
	}
	var hit := _cast(
		screen_position,
		ground_collision_mask
		| item_collision_mask
		| player_collision_mask
		| node_collision_mask,
	)
	if hit.is_empty():
		return miss

	var item := hit["collider"] as GroundItemScript
	if item != null:
		return {
			"target": Target.ITEM,
			"ground": Vector2.ZERO,
			"item": item,
			"node": null,
			"player": null,
		}

	var resource_node := hit["collider"] as ResourceNodeScript
	if resource_node != null:
		return {
			"target": Target.NODE,
			"ground": Vector2.ZERO,
			"item": null,
			"node": resource_node,
			"player": null,
		}

	var selectable := _selectable_from_collider(hit["collider"])
	if selectable != null:
		return {
			"target": Target.PLAYER,
			"ground": Vector2.ZERO,
			"item": null,
			"node": null,
			"player": selectable,
		}

	var point: Vector3 = hit["position"]
	if _is_on_mask(hit["collider"], item_collision_mask):
		push_error(
			"GroundPicker: %s is on the item collision layer but is not a ground item"
			% [hit["collider"]]
		)
		return miss
	if _is_on_mask(hit["collider"], node_collision_mask):
		push_error(
			"GroundPicker: %s is on the node collision layer but is not a resource node"
			% [hit["collider"]]
		)
		return miss
	if _is_on_mask(hit["collider"], player_collision_mask):
		push_error(
			"GroundPicker: %s is on the player collision layer but is not a selectable body"
			% [hit["collider"]]
		)
		return miss
	return {
		"target": Target.GROUND,
		"ground": Vector2(point.x, point.z),
		"item": null,
		"node": null,
		"player": null,
	}


func pick_ground(screen_position: Vector2) -> Variant:
	var hit := _cast(screen_position, ground_collision_mask)
	if hit.is_empty():
		return null
	var point: Vector3 = hit["position"]
	return Vector2(point.x, point.z)


func _cast(screen_position: Vector2, collision_mask: int) -> Dictionary:
	if camera == null:
		push_error("GroundPicker has no camera assigned; cannot pick.")
		return {}

	var space_state := camera.get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_position)
	var to := from + camera.project_ray_normal(screen_position) * ray_length

	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask)
	query.collide_with_bodies = true
	query.collide_with_areas = false

	return space_state.intersect_ray(query)


func _selectable_from_collider(collider: Object) -> Node3D:
	var avatar := collider as PlayerAvatarScript
	if avatar != null:
		return avatar
	var dummy := collider as NpcDummyScript
	if dummy != null:
		return dummy
	var node := collider as Node
	if node == null:
		return null
	var parent_avatar := node.get_parent() as PlayerAvatarScript
	if parent_avatar != null:
		return parent_avatar
	return node.get_parent() as NpcDummyScript


func _is_on_mask(collider: Object, mask: int) -> bool:
	var body := collider as CollisionObject3D
	if body == null:
		return false
	return (body.collision_layer & mask) != 0
