extends RefCounted


const REL_PATH := "shared/maps/arena_ring_of_trials_nav.json"
const MOVE_SEARCH_ITERS := 24

var vertices: Array = []
var polys: Array = []


static func load_arena() -> RefCounted:
	var path := resolve_path()
	if path.is_empty():
		push_error("nav_mesh: could not find %s" % REL_PATH)
		return null
	return load_json(path)


static func resolve_path() -> String:
	var env := OS.get_environment("MARQUE_ARENA_NAV")
	if not env.is_empty():
		return env
	var start := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var dir := start
	while not dir.is_empty():
		var candidate := dir.path_join(REL_PATH)
		if FileAccess.file_exists(candidate):
			return candidate
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


static func load_json(path: String) -> RefCounted:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("nav_mesh: could not open %s: %d" % [path, FileAccess.get_open_error()])
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("nav_mesh: %s root is not an object" % path)
		return null
	var raw: Dictionary = parsed
	var mesh := new()
	var raw_verts: Variant = raw.get("vertices", null)
	if typeof(raw_verts) != TYPE_ARRAY:
		push_error("nav_mesh: missing vertices array")
		return null
	for i in (raw_verts as Array).size():
		var v: Variant = (raw_verts as Array)[i]
		if typeof(v) != TYPE_ARRAY or (v as Array).size() != 3:
			push_error("nav_mesh: vertex %d has bad components" % i)
			return null
		var comps: Array = v
		mesh.vertices.append(Vector3(float(comps[0]), float(comps[1]), float(comps[2])))
	var raw_polys: Variant = raw.get("polygons", null)
	if typeof(raw_polys) != TYPE_ARRAY:
		push_error("nav_mesh: missing polygons array")
		return null
	var n := mesh.vertices.size()
	for i in (raw_polys as Array).size():
		var p: Variant = (raw_polys as Array)[i]
		if typeof(p) != TYPE_ARRAY or (p as Array).size() != 3:
			push_error("nav_mesh: polygon %d has bad indices" % i)
			return null
		var idx: Array = p
		var a := int(idx[0])
		var b := int(idx[1])
		var c := int(idx[2])
		if a < 0 or b < 0 or c < 0 or a >= n or b >= n or c >= n:
			push_error("nav_mesh: polygon %d out of range" % i)
			return null
		mesh.polys.append(Vector3i(a, b, c))
	return mesh


func contains_xz(x: float, z: float) -> bool:
	var sample := height_at(x, z, 0.0)
	return bool(sample["ok"])


func height_at(x: float, z: float, near_y: float) -> Dictionary:
	var best := 0.0
	var best_dist := INF
	var found := false
	for p in polys:
		var tri: Vector3i = p
		var a: Vector3 = vertices[tri.x]
		var b: Vector3 = vertices[tri.y]
		var c: Vector3 = vertices[tri.z]
		var bary := _barycentric_xz(x, z, a, b, c)
		if not bool(bary["ok"]):
			continue
		var hy: float = (
			float(bary["u"]) * a.y + float(bary["v"]) * b.y + float(bary["w"]) * c.y
		)
		var d := absf(hy - near_y)
		if not found or d < best_dist:
			best = hy
			best_dist = d
			found = true
	return {"y": best, "ok": found}


func move(from_x: float, from_z: float, to_x: float, to_z: float) -> Vector2:
	if not contains_xz(from_x, from_z):
		if contains_xz(to_x, to_z):
			return Vector2(to_x, to_z)
		return Vector2(from_x, from_z)
	var dx := to_x - from_x
	var dz := to_z - from_z
	var dist := sqrt(dx * dx + dz * dz)
	if dist < 1e-12:
		return Vector2(from_x, from_z)
	var steps := int(dist * 8.0)
	if steps < MOVE_SEARCH_ITERS:
		steps = MOVE_SEARCH_ITERS
	if steps > 512:
		steps = 512
	var last_on := 0.0
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var mx := from_x + dx * t
		var mz := from_z + dz * t
		if contains_xz(mx, mz):
			last_on = t
			continue
		var lo := last_on
		var hi := t
		for _j in MOVE_SEARCH_ITERS:
			var mid := (lo + hi) * 0.5
			if contains_xz(from_x + dx * mid, from_z + dz * mid):
				lo = mid
			else:
				hi = mid
		return Vector2(from_x + dx * lo, from_z + dz * lo)
	return Vector2(to_x, to_z)


static func _barycentric_xz(px: float, pz: float, a: Vector3, b: Vector3, c: Vector3) -> Dictionary:
	var v0x := b.x - a.x
	var v0z := b.z - a.z
	var v1x := c.x - a.x
	var v1z := c.z - a.z
	var v2x := px - a.x
	var v2z := pz - a.z
	var den := v0x * v1z - v1x * v0z
	if absf(den) < 1e-12:
		return {"u": 0.0, "v": 0.0, "w": 0.0, "ok": false}
	var v := (v2x * v1z - v1x * v2z) / den
	var w := (v0x * v2z - v2x * v0z) / den
	var u := 1.0 - v - w
	const EPS := -1e-9
	if u < EPS or v < EPS or w < EPS:
		return {"u": 0.0, "v": 0.0, "w": 0.0, "ok": false}
	return {"u": u, "v": v, "w": w, "ok": true}
