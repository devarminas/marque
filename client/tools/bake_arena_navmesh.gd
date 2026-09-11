extends SceneTree

const GLB_PATH := "res://assets/maps/arena_ring_of_trials.glb"
const SCENE_PATH := "res://scenes/arena_ring_of_trials.tscn"
const NAVMESH_PATH := "res://scenes/arena_ring_of_trials_navmesh.tres"

const AGENT_HEIGHT := 1.8
const AGENT_RADIUS := 0.4
const AGENT_MAX_CLIMB := 0.35
const AGENT_MAX_SLOPE := 45.0
const CELL_SIZE := 0.25
const CELL_HEIGHT := 0.2


func _initialize() -> void:
	var packed: PackedScene = load(GLB_PATH)
	if packed == null:
		push_error("bake_arena_navmesh: missing %s" % GLB_PATH)
		quit(1)
		return

	var arena: Node3D = packed.instantiate() as Node3D
	if arena == null:
		push_error("bake_arena_navmesh: GLB root is not Node3D")
		quit(1)
		return

	var navmesh := NavigationMesh.new()
	navmesh.agent_height = AGENT_HEIGHT
	navmesh.agent_radius = AGENT_RADIUS
	navmesh.agent_max_climb = AGENT_MAX_CLIMB
	navmesh.agent_max_slope = AGENT_MAX_SLOPE
	navmesh.cell_size = CELL_SIZE
	navmesh.cell_height = CELL_HEIGHT

	var source := NavigationMeshSourceGeometryData3D.new()
	var mesh_count := _add_meshes(source, arena, Transform3D.IDENTITY)
	if mesh_count <= 0:
		push_error("bake_arena_navmesh: no MeshInstance3D surfaces found")
		quit(1)
		return

	NavigationServer3D.bake_from_source_geometry_data(navmesh, source)

	var poly_count := navmesh.get_polygon_count()
	if poly_count <= 0:
		push_error("bake_arena_navmesh: bake produced 0 polygons (meshes=%d)" % mesh_count)
		quit(1)
		return

	var err := ResourceSaver.save(navmesh, NAVMESH_PATH)
	if err != OK:
		push_error("bake_arena_navmesh: save navmesh failed (%s)" % err)
		quit(1)
		return

	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("bake_arena_navmesh: missing authored scene %s" % SCENE_PATH)
		quit(1)
		return
	var root: Node = scene.instantiate()
	var region := root.get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if region == null:
		push_error("bake_arena_navmesh: scene has no NavigationRegion3D")
		quit(1)
		return
	region.navigation_mesh = load(NAVMESH_PATH)
	if region.navigation_mesh == null or region.navigation_mesh.get_polygon_count() <= 0:
		push_error("bake_arena_navmesh: scene region failed to load baked mesh")
		quit(1)
		return

	var verts: PackedVector3Array = navmesh.get_vertices()
	var aabb := AABB()
	if verts.size() > 0:
		aabb.position = verts[0]
		for v in verts:
			aabb = aabb.expand(v)

	print(
		"ARENA NAVMESH OK meshes=%d polygons=%d vertices=%d aabb=%s scene=%s navmesh=%s"
		% [mesh_count, poly_count, verts.size(), aabb, SCENE_PATH, NAVMESH_PATH]
	)
	quit(0)


func _add_meshes(
	source: NavigationMeshSourceGeometryData3D, node: Node, parent_xform: Transform3D
) -> int:
	var count := 0
	var local := parent_xform
	if node is Node3D:
		local = parent_xform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			source.add_mesh(mi.mesh, local)
			count += 1
	for child in node.get_children():
		count += _add_meshes(source, child, local)
	return count
