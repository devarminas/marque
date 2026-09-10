extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")
const Assertions := preload("res://tests/assertions.gd")

const EXACT_EPSILON := 0.002
const CHANNEL_EPSILON := 0.02
const AUTHORED_TREE_AABB_HEIGHT := 7.265
const TREE_HEIGHT_EPSILON := 0.05
const CROWN_SLACK := 0.3
const CANOPY_RAY_OFFSET := 1.5
const NODE_MASK := 8

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _container: Node3D = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	_root = MainScene.instantiate() as Node3D
	_root.name = "NodesClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_container = _root.get_node("ResourceNodes") as Node3D

	await get_tree().process_frame
	await get_tree().process_frame

	print("== nodes: the third registry, no server ==")
	_test_the_container_is_authored()
	_test_welcome_builds_node_bodies()
	_test_node_ids_are_a_separate_space()
	_test_node_spawn_and_state()
	_test_node_despawn()
	_test_look_for_is_total()
	_test_depleted_is_visually_distinct()
	_test_an_unknown_kind_is_magenta()
	_test_the_tree_art_resolved()
	_test_the_rock_art_and_state()
	_test_the_smelter_art()
	_test_the_click_target_covers_the_art()
	await _test_a_click_ray_reaches_the_body()
	_test_a_second_welcome_frees_nodes()

	print(
		"NODES RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_container_is_authored() -> void:
	_check(_container != null, "main.tscn authors a ResourceNodes container")
	_check(
		_container != null and _container.get_child_count() == 0,
		"which starts empty, because how many nodes exist is runtime information",
	)
	_check(
		_session != null and _session.known_node_ids().is_empty(),
		"and the session believes in no nodes before welcome",
	)


func _test_welcome_builds_node_bodies() -> void:
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":142,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"nodes":[{"id":1,"kind":"tree","x":5.0,"z":0.0,"state":"full"},'
		+ '{"id":2,"kind":"tree","x":-3.0,"z":4.0,"state":"depleted"}]}}'
	)
	_check(
		_session.known_node_ids() == [1, 2],
		"welcome.nodes registers both ids, got %s" % [_session.known_node_ids()],
	)
	var full: ResourceNodeScript = _session.node_for(1)
	_check(full != null, "node 1 has a body")
	if full != null:
		_check(full.get_parent() == _container, "hanging under ResourceNodes")
		_check(
			full.position.distance_to(Vector3(5.0, full.ground_y, 0.0)) < EXACT_EPSILON,
			"at the welcome position",
		)
		_check(full.state == "full", 'state is "full"')
		_check(
			full.showing() == ResourceNodeScript.Look.TREE,
			"full tree shows the tree, got %s" % _look_name(full.showing()),
		)
		_check(_visible_visuals(full) == 1, "and exactly one of the three visuals is visible")
	var depleted: ResourceNodeScript = _session.node_for(2)
	_check(depleted != null and depleted.is_depleted(), "node 2 starts depleted")
	if depleted != null:
		_check(
			depleted.showing() == ResourceNodeScript.Look.STUMP,
			"depleted tree shows the stump, got %s" % _look_name(depleted.showing()),
		)
		_check(_visible_visuals(depleted) == 1, "and exactly one of the three visuals is visible")


func _test_node_ids_are_a_separate_space() -> void:
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":10,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"items":[{"id":1,"kind":"acorn","x":1.0,"z":1.0}],'
		+ '"nodes":[{"id":1,"kind":"tree","x":2.0,"z":2.0,"state":"full"}]}}'
	)
	_check(_session.item_for(1) != null, "item 1 exists")
	_check(_session.node_for(1) != null, "node 1 exists")
	_check(
		_session.item_for(1) != (_session.node_for(1) as Object),
		"and they are different bodies sharing a number",
	)


func _test_node_spawn_and_state() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":7,"kind":"tree","x":3.0,"z":-2.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(7)
	_check(body != null, "node_spawn builds a body")
	if body == null:
		return
	_check(body.state == "full", "full on spawn")
	_feed('{"node_state":{"id":7,"kind":"tree","x":3.0,"z":-2.0,"state":"depleted"}}')
	_check(body.is_depleted(), "node_state depleted switches the visual state")
	_check(body.showing() == ResourceNodeScript.Look.STUMP, "down to the stump")
	_feed('{"node_state":{"id":7,"kind":"tree","x":3.0,"z":-2.0,"state":"full"}}')
	_check(not body.is_depleted(), "and full restores it")
	_check(body.showing() == ResourceNodeScript.Look.TREE, "back to the tree on respawn")
	_check(body.tree_visual.visible, "with the tree art drawn again")
	_check(not body.stump_visual.visible, "and the stump gone")
	_check(_visible_visuals(body) == 1, "still exactly one visual visible")
	_check(not body.canopy_shape.disabled, "and the canopy clickable again")


func _test_node_despawn() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":9,"kind":"tree","x":0.0,"z":0.0,"state":"full"}}')
	_check(_session.node_for(9) != null, "node 9 is present")
	_feed('{"node_despawn":{"id":9}}')
	_check(_session.node_for(9) == null, "node_despawn removes it")
	_check(
		_container.get_child_count() == 0,
		"leaving ResourceNodes empty, got %d" % _container.get_child_count(),
	)


func _test_look_for_is_total() -> void:
	_check(
		ResourceNodeScript.look_for(true, "full") == ResourceNodeScript.Look.TREE,
		"look_for(known, full) is TREE",
	)
	_check(
		ResourceNodeScript.look_for(true, "depleted") == ResourceNodeScript.Look.STUMP,
		"look_for(known, depleted) is STUMP",
	)
	_check(
		ResourceNodeScript.look_for(false, "full") == ResourceNodeScript.Look.MISSING,
		"look_for(unknown, full) is MISSING",
	)
	_check(
		ResourceNodeScript.look_for(false, "depleted") == ResourceNodeScript.Look.MISSING,
		"look_for(unknown, depleted) is MISSING too, the kind outranks the state",
	)


func _test_depleted_is_visually_distinct() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":4,"kind":"tree","x":0.0,"z":0.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(4)
	_check(body != null, "full tree exists")
	if body == null:
		return
	_check(body.showing() == ResourceNodeScript.Look.TREE, "showing TREE while full")
	_check(body.tree_visual != null and body.tree_visual.visible, "tree visual on while full")
	_check(body.stump_visual != null and not body.stump_visual.visible, "stump off while full")
	_check(body.scale == Vector3.ONE, "and the body carries no scale while full")
	_check(
		body.canopy_shape != null and not body.canopy_shape.disabled,
		"the canopy is clickable while full",
	)
	_check(body.trunk_shape != null and not body.trunk_shape.disabled, "and so is the trunk")
	_feed('{"node_state":{"id":4,"kind":"tree","x":0.0,"z":0.0,"state":"depleted"}}')
	_check(body.is_depleted(), "now depleted")
	_check(body.showing() == ResourceNodeScript.Look.STUMP, "showing STUMP once depleted")
	_check(not body.tree_visual.visible, "the tree visual went off")
	_check(body.stump_visual.visible, "the stump visual came on")
	_check(body.scale == Vector3.ONE, "and depletion still did not touch the body scale")
	_check(body.canopy_shape.disabled, "the canopy hitbox is gone with the canopy")
	_check(not body.trunk_shape.disabled, "while the trunk stays clickable")


func _test_an_unknown_kind_is_magenta() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":11,"kind":"crystal","x":0.0,"z":0.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(11)
	_check(body != null, "unknown kind still builds a body")
	if body == null:
		return
	_check(not body.is_kind_known(), "kind is unknown")
	_check(
		body.showing() == ResourceNodeScript.Look.MISSING,
		"showing MISSING, got %s" % _look_name(body.showing()),
	)
	_check(body.missing_visual != null and body.missing_visual.visible, "the marker is visible")
	_check(body.tree_visual != null and not body.tree_visual.visible, "and the tree art is not")
	var color := _override_color(body.missing_visual)
	_check(
		absf(color.r - 0.95) < CHANNEL_EPSILON
		and absf(color.g - 0.08) < CHANNEL_EPSILON
		and absf(color.b - 0.85) < CHANNEL_EPSILON,
		"and the marker draws magenta, got %s" % color,
	)
	_feed('{"node_state":{"id":11,"kind":"crystal","x":0.0,"z":0.0,"state":"depleted"}}')
	_check(body.is_depleted(), "an unknown kind still tracks its state")
	_check(
		body.showing() == ResourceNodeScript.Look.MISSING,
		"but stays MISSING when depleted, got %s" % _look_name(body.showing()),
	)
	_check(_visible_visuals(body) == 1, "with exactly one visual visible")


func _test_the_tree_art_resolved() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":12,"kind":"tree","x":0.0,"z":0.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(12)
	_check(body != null and body.tree_visual != null, "the tree body has a tree visual")
	if body == null or body.tree_visual == null:
		return
	_check(
		body.tree_visual.scale == Vector3.ONE,
		"which carries no scale, got %s" % body.tree_visual.scale,
	)
	var meshes := body.tree_visual.find_children("*", "MeshInstance3D", true, false)
	_check(meshes.size() >= 1, "and holds vendor mesh art, found %d MeshInstance3D" % meshes.size())
	if meshes.is_empty():
		return
	var art := meshes[0] as MeshInstance3D
	var surfaces := 0 if art.mesh == null else art.mesh.get_surface_count()
	_check(surfaces == 2, "with bark and leaves as two surfaces, got %d" % surfaces)
	if art.mesh == null:
		return
	_assertions.check_near(
		art.get_aabb().size.y,
		AUTHORED_TREE_AABB_HEIGHT,
		TREE_HEIGHT_EPSILON,
		"and spans its authored bounding height, root tip to crown",
	)


func _test_the_rock_art_and_state() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":15,"kind":"rock","x":2.0,"z":3.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(15)
	_check(body != null, "rock node builds a body")
	if body == null:
		return
	_check(body.is_kind_known(), "rock is a known kind")
	_check(body.is_rock(), "kind is rock")
	_check(
		body.showing() == ResourceNodeScript.Look.TREE,
		"full rock uses the full look, got %s" % _look_name(body.showing()),
	)
	_check(body.rock_visual != null and body.rock_visual.visible, "rock visual on while full")
	_check(
		body.rock_depleted_visual != null and not body.rock_depleted_visual.visible,
		"pebble off while full",
	)
	_check(body.tree_visual != null and not body.tree_visual.visible, "tree art stays off")
	_check(body.stump_visual != null and not body.stump_visual.visible, "stump stays off")
	_check(body.canopy_shape != null and body.canopy_shape.disabled, "rock has no canopy hitbox")
	_check(_visible_visuals(body) == 1, "exactly one rock visual visible while full")
	var meshes := body.rock_visual.find_children("*", "MeshInstance3D", true, false)
	_check(meshes.size() >= 1, "rock holds vendor mesh art, found %d" % meshes.size())
	_feed('{"node_state":{"id":15,"kind":"rock","x":2.0,"z":3.0,"state":"depleted"}}')
	_check(body.is_depleted(), "rock tracks depleted")
	_check(
		body.showing() == ResourceNodeScript.Look.STUMP,
		"depleted rock uses the depleted look, got %s" % _look_name(body.showing()),
	)
	_check(not body.rock_visual.visible, "full rock art went off")
	_check(body.rock_depleted_visual.visible, "pebble came on")
	_check(_visible_visuals(body) == 1, "exactly one visual visible while depleted")
	_feed('{"node_state":{"id":15,"kind":"rock","x":2.0,"z":3.0,"state":"full"}}')
	_check(not body.is_depleted(), "rock respawns to full")
	_check(body.rock_visual.visible, "rock art returns")
	_check(not body.rock_depleted_visual.visible, "pebble leaves")


func _test_the_smelter_art() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":16,"kind":"smelter","x":0.0,"z":3.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(16)
	_check(body != null, "smelter node builds a body")
	if body == null:
		return
	_check(body.is_kind_known(), "smelter is a known kind")
	_check(body.is_smelter(), "kind is smelter")
	_check(not body.is_gatherable(), "smelter is not gatherable")
	_check(
		body.showing() == ResourceNodeScript.Look.TREE,
		"full smelter uses the full look, got %s" % _look_name(body.showing()),
	)
	_check(body.smelter_visual != null and body.smelter_visual.visible, "smelter visual on")
	_check(body.tree_visual != null and not body.tree_visual.visible, "tree art stays off")
	_check(body.rock_visual != null and not body.rock_visual.visible, "rock art stays off")
	_check(body.canopy_shape != null and body.canopy_shape.disabled, "smelter has no canopy hitbox")
	_check(_visible_visuals(body) == 1, "exactly one smelter visual visible")
	var meshes := body.smelter_visual.find_children("*", "MeshInstance3D", true, false)
	_check(meshes.size() >= 1, "smelter holds vendor mesh art, found %d" % meshes.size())


func _test_the_click_target_covers_the_art() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":14,"kind":"tree","x":0.0,"z":0.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(14)
	_check(body != null, "the tree to measure exists")
	if body == null:
		return
	var meshes := body.tree_visual.find_children("*", "MeshInstance3D", true, false)
	_check(not meshes.is_empty(), "and holds the mesh art to measure the hitboxes against")
	if meshes.is_empty():
		return
	var art: AABB = (meshes[0] as MeshInstance3D).get_aabb()
	var trunk := body.trunk_shape.shape as CylinderShape3D
	var canopy := body.canopy_shape.shape as SphereShape3D
	_check(trunk != null and canopy != null, "the hitboxes are a cylinder and a sphere")
	if trunk == null or canopy == null:
		return
	var trunk_bottom := body.trunk_shape.position.y - trunk.height / 2.0
	var trunk_top := body.trunk_shape.position.y + trunk.height / 2.0
	var canopy_bottom := body.canopy_shape.position.y - canopy.radius
	var canopy_top := body.canopy_shape.position.y + canopy.radius
	var art_top := art.position.y + art.size.y
	var art_half_width := maxf(art.size.x, art.size.z) / 2.0
	_check(
		trunk_bottom <= 0.0,
		"the trunk hitbox reaches the ground, starting at %.2f" % trunk_bottom,
	)
	_check(
		trunk_top >= canopy_bottom,
		"and meets the canopy hitbox with no unclickable band, %.2f against %.2f"
			% [trunk_top, canopy_bottom],
	)
	_check(
		canopy_top >= art_top - CROWN_SLACK,
		"the hitbox reaches the drawn crown, %.2f against art top %.2f" % [canopy_top, art_top],
	)
	_check(
		canopy.radius >= art_half_width - CROWN_SLACK,
		"and is as wide as the drawn canopy, %.2f against art half-width %.2f"
			% [canopy.radius, art_half_width],
	)


func _test_a_click_ray_reaches_the_body() -> void:
	_feed(_welcome_empty())
	_feed('{"node_spawn":{"id":13,"kind":"tree","x":0.0,"z":0.0,"state":"full"}}')
	var body: ResourceNodeScript = _session.node_for(13)
	_check(body != null, "the clickable tree exists")
	if body == null:
		return
	await get_tree().physics_frame
	_check(_hit_from_above(body), "a straight-down ray on mask 8 finds the full tree")
	_check(_hit_at_aim_height(body), "and so does a ray through the demos' y=1.8 aim point")
	_check(
		_hit_through_canopy(body) == body,
		"and so does a ray %.1f u off the trunk axis at canopy height, where only CanopyShape sits"
			% CANOPY_RAY_OFFSET,
	)
	_feed('{"node_state":{"id":13,"kind":"tree","x":0.0,"z":0.0,"state":"depleted"}}')
	await get_tree().physics_frame
	_check(_hit_from_above(body), "the depleted stump is still hit from straight above")
	_check(_hit_at_aim_height(body), "and still hit at the demos' y=1.8 aim point")
	_check(
		_hit_through_canopy(body) == null,
		"while the canopy ray now hits nothing, so depletion removed the hitbox, not just a flag",
	)


func _test_a_second_welcome_frees_nodes() -> void:
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"nodes":[{"id":1,"kind":"tree","x":1.0,"z":1.0,"state":"full"}]}}'
	)
	_check(_session.node_for(1) != null, "first welcome has a node")
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":2,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"nodes":[{"id":8,"kind":"tree","x":2.0,"z":2.0,"state":"full"}]}}'
	)
	_check(_session.node_for(1) == null, "second welcome drops the old node")
	_check(_session.node_for(8) != null, "and builds the new one")


func _hit_from_above(body: ResourceNodeScript) -> bool:
	var origin := body.global_position
	return _cast(origin + Vector3(0.0, 6.0, 0.0), origin - Vector3(0.0, 1.0, 0.0)) == body


func _hit_at_aim_height(body: ResourceNodeScript) -> bool:
	var aim := body.global_position + Vector3(0.0, 1.8, 0.0)
	return _cast(aim + Vector3(6.0, 0.6, 0.0), aim + Vector3(-6.0, -0.6, 0.0)) == body


func _hit_through_canopy(body: ResourceNodeScript) -> Object:
	var aim := body.global_position + Vector3(
		0.0, body.canopy_shape.position.y, CANOPY_RAY_OFFSET
	)
	return _cast(aim - Vector3(6.0, 0.0, 0.0), aim + Vector3(6.0, 0.0, 0.0))


func _cast(from: Vector3, to: Vector3) -> Object:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, NODE_MASK)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit["collider"]


func _visible_visuals(body: ResourceNodeScript) -> int:
	var count := 0
	for visual in [
		body.tree_visual,
		body.stump_visual,
		body.rock_visual,
		body.rock_depleted_visual,
		body.smelter_visual,
		body.missing_visual,
	]:
		if visual != null and visual.visible:
			count += 1
	return count


static func _override_color(visual: MeshInstance3D) -> Color:
	if visual == null:
		return Color.BLACK
	var material := visual.material_override as StandardMaterial3D
	if material == null:
		return Color.BLACK
	return material.albedo_color


static func _look_name(look: ResourceNodeScript.Look) -> String:
	match look:
		ResourceNodeScript.Look.TREE:
			return "TREE"
		ResourceNodeScript.Look.STUMP:
			return "STUMP"
		ResourceNodeScript.Look.MISSING:
			return "MISSING"
	return "UNKNOWN(%d)" % look


func _welcome_empty() -> String:
	return (
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}]}}'
	)


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
