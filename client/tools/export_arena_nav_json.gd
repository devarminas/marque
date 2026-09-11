extends SceneTree

const NAVMESH_PATH := "res://scenes/arena_ring_of_trials_navmesh.tres"
const OUT_PATH := "res://../shared/maps/arena_ring_of_trials_nav.json"
const AGENT_RADIUS := 0.4


func _initialize() -> void:
	var nav: NavigationMesh = load(NAVMESH_PATH)
	if nav == null:
		push_error("export_arena_nav_json: missing %s" % NAVMESH_PATH)
		quit(1)
		return

	var verts: PackedVector3Array = nav.get_vertices()
	var vertices: Array = []
	for v in verts:
		vertices.append([snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)])

	var polygons: Array = []
	for i in nav.get_polygon_count():
		var poly: PackedInt32Array = nav.get_polygon(i)
		var idxs: Array = []
		for idx in poly:
			idxs.append(int(idx))
		polygons.append(idxs)

	var payload := {
		"id": "arena_ring_of_trials",
		"agent_radius": AGENT_RADIUS,
		"vertices": vertices,
		"polygons": polygons,
	}

	var abs_out := ProjectSettings.globalize_path(OUT_PATH)
	DirAccess.make_dir_recursive_absolute(abs_out.get_base_dir())
	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("export_arena_nav_json: cannot write %s" % OUT_PATH)
		quit(1)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()

	if polygons.is_empty() or vertices.is_empty():
		push_error("export_arena_nav_json: empty mesh")
		quit(1)
		return

	print("ARENA NAV JSON OK path=%s" % abs_out)
	quit(0)
