class_name GroundPicker
extends Node

## Turns a cursor position into what the player clicked: a ground-plane
## [code](x, z)[/code] coordinate, or a ground item.
##
## Producing the answer is the whole job. This node does not move anything, does
## not pick anything up, and does not talk to a network: `session.gd` connects
## [signal ground_clicked] to a [code]{"move_to":{"x":..,"z":..}}[/code] intent
## and [signal item_clicked] to a [code]{"pickup":{"item":..}}[/code] one.
## Keeping the two apart is the "game logic never reaches into the visual tree"
## invariant from CLAUDE.md — the raycast hands out a number or a body, it does
## not act on either.
##
## [b]One ray decides, not two.[/b] **M1d.** The ground is on collision layer 1
## and every [code]ground_item.tscn[/code] body is on layer 2, and
## [method pick] queries both in a single [method PhysicsDirectSpaceState3D.intersect_ray],
## which returns the [i]nearest[/i] intersection. So the click is classified by
## which surface is actually in front of the cursor, which is what a player
## means by clicking a thing. Two separate queries would each report a hit for a
## cursor over an item and leave somebody to guess which one won — and guessing
## it by "items first" is right only until something is ever behind something
## else.
##
## [b]The item's id is deliberately not read here.[/b] [signal item_clicked]
## carries the body, and `session.gd` looks that body up in the registry the
## server's frames built. A picker that read an [code]item_id[/code] off a node
## and handed over the integer would let any node claiming that property put an
## id on the wire; the id has to come from the registry or it is invented.

## Emitted on a left click whose ray meets the ground first.
## [param x] and [param z] are Godot world units on the ground plane.
signal ground_clicked(x: float, z: float)

## Emitted on a left click whose ray meets a ground item first. **M1.**
##
## [param item] is a [code]ground_item.gd[/code] body. It is the body and not an
## id on purpose; see the class docs.
signal item_clicked(item: Node3D)

## What one click resolved to. Exactly one of these describes any given click.
enum Target {
	## The ray met nothing: a cursor on the sky.
	NOTHING,
	## The ray met the ground first.
	GROUND,
	## The ray met a ground item first.
	ITEM,
}

const GroundItemScript := preload("res://scripts/ground_item.gd")

## The camera the ray is projected from.
@export var camera: Camera3D
## How far the ray travels before giving up. Must exceed the far side of the
## world from any legal camera position, or distant clicks silently miss.
@export var ray_length := 4096.0
## Must match the ground body's collision layer. Left at the physics default
## this query quietly matches the wrong set of bodies, and the symptom is a
## raycast that never hits — indistinguishable from a broken ray.
@export_flags_3d_physics var ground_collision_mask := 1
## Must match [code]ground_item.tscn[/code]'s collision layer, and must not
## overlap [member ground_collision_mask]: the two are what tells one kind of
## click from the other, so a mask covering both would make every ground click
## look like an item click and vice versa.
@export_flags_3d_physics var item_collision_mask := 2


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return
	var picked := pick(button.position)
	match picked["target"]:
		Target.ITEM:
			item_clicked.emit(picked["item"])
		Target.GROUND:
			var ground: Vector2 = picked["ground"]
			# ground.y is world Z, not world Y. See pick_ground().
			ground_clicked.emit(ground.x, ground.y)
		_:
			pass


## Resolves [param screen_position] to what is under it, in one query.
##
## Always returns all three keys, so a caller switches on [code]target[/code]
## rather than probing for presence:
##
## [codeblock]
## {"target": Target, "ground": Vector2, "item": Node3D}
## [/codeblock]
##
## [code]ground[/code] is meaningful only for [constant Target.GROUND] and is
## the ground-plane [code](x, z)[/code] the ray landed on, so [code]y[/code]
## holds world [b]Z[/b]. [code]item[/code] is meaningful only for
## [constant Target.ITEM].
##
## Precondition: the physics space has stepped at least once. A query issued
## from the first frame of [method Node._ready] finds nothing and looks exactly
## like a broken raycast.
func pick(screen_position: Vector2) -> Dictionary:
	var miss := {"target": Target.NOTHING, "ground": Vector2.ZERO, "item": null}
	var hit := _cast(screen_position, ground_collision_mask | item_collision_mask)
	if hit.is_empty():
		return miss

	# The collider is an item only when it really is one of these bodies. A cast
	# that fails yields null rather than a half-typed node, so a body that
	# happens to sit on the item layer without being an item cannot be picked
	# up; it is reported loudly instead of quietly becoming a pickup intent.
	var item := hit["collider"] as GroundItemScript
	if item != null:
		return {"target": Target.ITEM, "ground": Vector2.ZERO, "item": item}

	var point: Vector3 = hit["position"]
	if _is_on_item_layer(hit["collider"]):
		push_error(
			"GroundPicker: %s is on the item collision layer but is not a ground item"
			% [hit["collider"]]
		)
		return miss
	return {"target": Target.GROUND, "ground": Vector2(point.x, point.z), "item": null}


## Projects a ray from [member camera] through [param screen_position] into the
## physics space and returns where it meets [b]the ground[/b].
##
## Returns a [Vector2] whose [code]x[/code] is world X and whose [code]y[/code]
## is world [b]Z[/b], or [code]null[/code] when the ray misses the ground — a
## cursor on the sky, for instance. A miss is a miss, not a coordinate.
##
## [b]This is not what a click does[/b], and the difference is the point. It
## queries [member ground_collision_mask] alone, so a cursor over an item
## answers with the ground [i]underneath[/i] the item rather than with the item.
## That is the right answer to "where is the ground under this cursor", which is
## what the demo scripts and the camera-facing tests ask. [method pick] answers
## the different question of what the player clicked.
##
## Precondition: as [method pick].
func pick_ground(screen_position: Vector2) -> Variant:
	var hit := _cast(screen_position, ground_collision_mask)
	if hit.is_empty():
		return null

	var point: Vector3 = hit["position"]
	# y is dropped deliberately, not lost. Movement is two-dimensional: the
	# server stores and paths over (x, z) only and never sees a y, so the height
	# this ray happened to land on carries no information downstream
	# (NOTES.md, "Movement"). Discarding a value looks like a bug otherwise.
	return Vector2(point.x, point.z)


## One ray from the camera through [param screen_position], against
## [param collision_mask]. Empty when it meets nothing, and empty when there is
## no camera to cast from.
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


## True when [param collider] sits on any bit of [member item_collision_mask].
## Only used to explain a hit that is on the item layer and is not an item.
func _is_on_item_layer(collider: Object) -> bool:
	var body := collider as CollisionObject3D
	if body == null:
		return false
	return (body.collision_layer & item_collision_mask) != 0
