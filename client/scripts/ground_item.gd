extends StaticBody3D

## One ground item's body. Instanced once per live item id by `session.gd`.
##
## The scene is [code]res://scenes/ground_item.tscn[/code]. How many items are
## lying on the ground is genuine runtime information, so instancing it in
## script is the case CLAUDE.md's scene-authoring rule explicitly allows. Its
## [i]contents[/i] — the mesh, its collision shape, its size, and both materials
## — are authored in the scene file and nothing here builds a node.
##
## [b]It is a body so that a click can land on it.[/b] **M1d.** The root is a
## [StaticBody3D] on collision layer 2, the ground is on layer 1, and
## [code]ground_picker.gd[/code] casts one ray against both: the nearest surface
## wins, so a cursor over an item resolves to the item and a cursor beside it
## resolves to the ground. That is a physics fact rather than a rule anybody
## wrote, which is why the picker does not have to guess afterwards which of the
## two a click meant. Layer 2 is not decoration: `pick_ground()` still queries
## layer 1 alone and still answers "where is the ground under this cursor",
## which is a different question and stays available to the demo scripts.
##
## The collision box matches the drawn box exactly. A generous click target
## would be kinder to a player and would also be a lie about where the item is,
## and the first time those two disagree the bug is invisible.
##
## [b]This is not an avatar.[/b] It never walks, so it owns no
## [code]polyline_walker.gd[/code], no clock, and no facing. Item ids and player
## ids are separate spaces (PROTOCOL.md, "Identity"), and this script deliberately
## shares no code with [code]player_avatar.gd[/code] so that nothing can key the
## two together by accident.
##
## Usage from the session:
##
## [codeblock]
## const GroundItemScene := preload("res://scenes/ground_item.tscn")
##
## var body := GroundItemScene.instantiate()
## body.configure(item_id, "acorn")   # unknown kinds render magenta
## ground_items.add_child(body)       # /root/Main/GroundItems
## body.place_at(x, z)
## [/codeblock]
##
## Typed by [code]preload[/code] rather than by global [code]class_name[/code],
## per NOTES.md, "Godot authoring traps".

## The kinds this client has art for. **M1d** moved the list to its own file
## because the inventory panel draws the same kinds this body does, and two
## copies could disagree about one of them.
const ItemKinds := preload("res://scripts/item_kinds.gd")

## Server item id, or 0 before [method configure]. Item ids are assigned from 1
## (PROTOCOL.md, "Identity"), so 0 means unconfigured.
var item_id := 0

## `item_spawn.kind`, or "" before [method configure]. Held verbatim, including
## a kind this client does not know: the server's name for the thing is worth
## more in a log than this client's opinion of it.
var kind := ""

## Y the item sits at. [code]y[/code] never appears on the wire and is the
## client's business (PROTOCOL.md, "Coordinates"); on M0's flat plane it is a
## constant, and it is the same constant [code]player_avatar.gd[/code] uses so
## that an item and a player standing on one spot share a ground. Both become a
## terrain query at the same time, and neither before the other.
@export var ground_y := 0.0

## The one [MeshInstance3D] this body draws. Authored in the scene; assigned by
## [code]node_paths[/code] on the [code][node][/code] header, without which an
## exported node path silently resolves to null (NOTES.md).
@export var mesh: MeshInstance3D

## Drawn for a `kind` in [constant KNOWN_KINDS]. Green is Pickup (NOTES.md).
@export var known_material: StandardMaterial3D

## Drawn for anything else. Magenta is missing-asset (NOTES.md).
@export var unknown_material: StandardMaterial3D


## Binds this body to an item id and a kind, and picks which material it draws.
##
## Both materials are authored in the scene and neither is ever mutated: every
## instance of this scene shares the same two [StandardMaterial3D] objects, so
## writing to one would repaint every item in the world.
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


## Places the body at ground-plane [code](x, z)[/code].
##
## There is no interpolated form. A ground item does not move: it is spawned
## where it lies and despawned when it is taken, and PROTOCOL.md gives it no
## message that would move one.
func place_at(x: float, z: float) -> void:
	position = Vector3(x, ground_y, z)


## True when this client has art for [member kind].
func is_kind_known() -> bool:
	return ItemKinds.is_known(kind)


## The colour this body is actually drawing, as opposed to the one it meant to.
##
## Read off the material the mesh ended up with, so a test asserting "an unknown
## kind is magenta" asserts what a screenshot would show rather than what
## [method configure] intended.
func display_color() -> Color:
	if mesh == null:
		return Color(0, 0, 0, 0)
	var material := mesh.material_override as StandardMaterial3D
	if material == null:
		return Color(0, 0, 0, 0)
	return material.albedo_color


## The body's extent in its own space.
##
## Exists so that "an item is not shaped like a player" is a checkable claim and
## not only a thing a screenshot shows. A player capsule is 1.8 units tall; this
## is a fraction of that.
func local_bounds() -> AABB:
	if mesh == null:
		return AABB()
	return mesh.transform * mesh.get_aabb()
