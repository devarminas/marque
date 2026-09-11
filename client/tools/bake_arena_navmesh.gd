extends SceneTree

const GLB_PATH := "res://assets/maps/arena_ring_of_trials.glb"
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

	if navmesh.get_polygon_count() <= 0:
		push_error("bake_arena_navmesh: bake produced an empty mesh (meshes=%d)" % mesh_count)
		quit(1)
		return

	var err := ResourceSaver.save(navmesh, NAVMESH_PATH)
	if err != OK:
		push_error("bake_arena_navmesh: save navmesh failed (%s)" % err)
		quit(1)
		return

	print("ARENA NAVMESH OK meshes=%d path=%s" % [mesh_count, NAVMESH_PATH])
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
