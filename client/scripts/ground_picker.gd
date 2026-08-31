class_name GroundPicker
extends Node

## Turns a cursor position into a ground-plane [code](x, z)[/code] coordinate.
##
## Producing the coordinate is the whole job. This node does not move anything
## and does not talk to a network: a later unit connects
## [signal ground_clicked] to a [code]{"move_to":{"x":..,"z":..}}[/code] intent.
## Keeping the two apart is the "game logic never reaches into the visual tree"
## invariant from CLAUDE.md — the raycast hands out a number, it does not act.

## Emitted on a left click whose ray meets the ground.
## [param x] and [param z] are Godot world units on the ground plane.
signal ground_clicked(x: float, z: float)

## The camera the ray is projected from.
@export var camera: Camera3D
## How far the ray travels before giving up. Must exceed the far side of the
## world from any legal camera position, or distant clicks silently miss.
@export var ray_length := 4096.0
## Must match the ground body's collision layer. Left at the physics default
## this query quietly matches the wrong set of bodies, and the symptom is a
## raycast that never hits — indistinguishable from a broken ray.
@export_flags_3d_physics var ground_collision_mask := 1


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return
	var ground = pick_ground(button.position)
	if ground == null:
		return
	var ground_xz: Vector2 = ground
	# ground_xz.y is world Z, not world Y. See pick_ground().
	ground_clicked.emit(ground_xz.x, ground_xz.y)


## Projects a ray from [member camera] through [param screen_position] into the
## physics space and returns where it meets the ground.
##
## Returns a [Vector2] whose [code]x[/code] is world X and whose [code]y[/code]
## is world [b]Z[/b], or [code]null[/code] when the ray misses the ground — a
## cursor on the sky, for instance. A miss is a miss, not a coordinate.
##
## Precondition: the physics space has stepped at least once. A query issued
## from the first frame of [method Node._ready] finds nothing and looks exactly
## like a broken raycast.
func pick_ground(screen_position: Vector2) -> Variant:
	if camera == null:
		push_error("GroundPicker has no camera assigned; cannot pick.")
		return null

	var space_state := camera.get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_position)
	var to := from + camera.project_ray_normal(screen_position) * ray_length

	var query := PhysicsRayQueryParameters3D.create(from, to, ground_collision_mask)
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return null

	var point: Vector3 = hit["position"]
	# y is dropped deliberately, not lost. Movement is two-dimensional: the
	# server stores and paths over (x, z) only and never sees a y, so the height
	# this ray happened to land on carries no information downstream
	# (NOTES.md, "Movement"). Discarding a value looks like a bug otherwise.
	return Vector2(point.x, point.z)
