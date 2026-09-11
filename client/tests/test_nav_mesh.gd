extends RefCounted


const NavMesh := preload("res://scripts/nav_mesh.gd")
const Assertions := preload("res://tests/assertions.gd")

const POSITION_EPSILON := 1.0e-3


func run(assertions: Assertions) -> void:
	_test_load_arena(assertions)
	_test_height_at_origin(assertions)
	_test_height_prefers_near_y(assertions)
	_test_move_stops_at_boundary(assertions)
	_test_move_does_not_tunnel_hole(assertions)
	assertions.finish()


func _test_load_arena(assertions: Assertions) -> void:
	var mesh = NavMesh.load_arena()
	assertions.check(mesh != null, "arena nav JSON loads")
	assertions.check(mesh.vertices.size() > 0, "arena has vertices")
	assertions.check(mesh.polys.size() > 0, "arena has polygons")


func _test_height_at_origin(assertions: Assertions) -> void:
	var mesh = NavMesh.load_arena()
	var sample: Dictionary = mesh.height_at(0.0, 0.0, 0.0)
	assertions.check(bool(sample["ok"]), "(0,0) on arena mesh")
	assertions.check(not is_nan(float(sample["y"])), "origin height is finite")


func _test_height_prefers_near_y(assertions: Assertions) -> void:
	var mesh = NavMesh.load_arena()
	var low: Dictionary = mesh.height_at(-9.0, -8.0, 0.4)
	var high: Dictionary = mesh.height_at(-9.0, -8.0, 10.4)
	assertions.check(bool(low["ok"]) and bool(high["ok"]), "stacked sample on mesh")
	assertions.check_near(float(low["y"]), 0.4, POSITION_EPSILON, "near floor ~0.4")
	assertions.check_near(float(high["y"]), 10.4, POSITION_EPSILON, "near deck ~10.4")


func _test_move_stops_at_boundary(assertions: Assertions) -> void:
	var mesh = NavMesh.load_arena()
	assertions.check(mesh.contains_xz(0.0, 0.0), "from on mesh")
	var hit: Vector2 = mesh.move(0.0, 0.0, 200.0, 0.0)
	assertions.check(mesh.contains_xz(hit.x, hit.y), "Move result stays on mesh")
	assertions.check(not mesh.contains_xz(200.0, 0.0), "far destination off mesh")
	assertions.check(hit.length() > 1.0, "Move advanced toward the wall")
	assertions.check(Vector2(hit.x - 200.0, hit.y).length() > 1.0, "Move did not reach far off-mesh")


func _test_move_does_not_tunnel_hole(assertions: Assertions) -> void:
	var mesh = NavMesh.load_arena()
	var from := Vector2(-22.0, 5.0)
	var to := Vector2(-21.0, 6.0)
	assertions.check(mesh.contains_xz(from.x, from.y), "hole from on mesh")
	assertions.check(mesh.contains_xz(to.x, to.y), "hole to on mesh")
	assertions.check(
		not mesh.contains_xz((from.x + to.x) * 0.5, (from.y + to.y) * 0.5),
		"hole midpoint off mesh",
	)
	var hit: Vector2 = mesh.move(from.x, from.y, to.x, to.y)
	assertions.check(mesh.contains_xz(hit.x, hit.y), "hole Move stays on mesh")
	assertions.check(
		Vector2(hit.x - to.x, hit.y - to.y).length() > 1e-3,
		"hole Move does not tunnel to far side",
	)
