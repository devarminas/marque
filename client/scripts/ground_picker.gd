class_name GroundPicker
extends Node

## Turns a cursor position into what the player clicked: ground, a ground item,
## or a resource node.
##
## Producing the answer is the whole job. This node does not move anything, does
## not pick anything up, and does not talk to a network: `session.gd` connects
## the signals to intents. Keeping them apart is the "game logic never reaches
## into the visual tree" invariant from CLAUDE.md.
##
## [b]One ray decides, not two.[/b] Ground is layer 1, ground items layer 2,
## resource nodes layer 3. [method pick] queries all three in one
## [method PhysicsDirectSpaceState3D.intersect_ray]; the nearest surface wins.
##
## Ids are not read here. [signal item_clicked] and [signal node_clicked] carry
## the body; `session.gd` looks that body up in the registry the server's frames
## built.

signal ground_clicked(x: float, z: float)

## Emitted on a left click whose ray meets a ground item first. **M1.**
signal item_clicked(item: Node3D)

## Emitted on a left click whose ray meets a resource node first. **M4b.**
signal node_clicked(resource_node: Node3D)

enum Target {
	NOTHING,
	GROUND,
	ITEM,
	NODE,
}

const GroundItemScript := preload("res://scripts/ground_item.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")

@export var camera: Camera3D
@export var ray_length := 4096.0
@export_flags_3d_physics var ground_collision_mask := 1
@export_flags_3d_physics var item_collision_mask := 2
@export_flags_3d_physics var node_collision_mask := 4


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return
	var picked := pick(button.position)
	match picked["target"]:
		Target.ITEM:
			item_clicked.emit(picked["item"])
		Target.NODE:
			node_clicked.emit(picked["node"])
		Target.GROUND:
			var ground: Vector2 = picked["ground"]
			ground_clicked.emit(ground.x, ground.y)
		_:
			pass


## Resolves [param screen_position] to what is under it, in one query.
##
## Always returns all four keys:
## [code]{"target": Target, "ground": Vector2, "item": Node3D, "node": Node3D}[/code]
func pick(screen_position: Vector2) -> Dictionary:
	var miss := {
		"target": Target.NOTHING,
		"ground": Vector2.ZERO,
		"item": null,
		"node": null,
	}
	var hit := _cast(
		screen_position,
		ground_collision_mask | item_collision_mask | node_collision_mask,
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
		}

	var resource_node := hit["collider"] as ResourceNodeScript
	if resource_node != null:
		return {
			"target": Target.NODE,
			"ground": Vector2.ZERO,
			"item": null,
			"node": resource_node,
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
	return {
		"target": Target.GROUND,
		"ground": Vector2(point.x, point.z),
		"item": null,
		"node": null,
	}


## Projects a ray against the ground layer alone.
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


func _is_on_mask(collider: Object, mask: int) -> bool:
	var body := collider as CollisionObject3D
	if body == null:
		return false
	return (body.collision_layer & mask) != 0
