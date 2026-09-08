extends Node3D


const WorldMapScene := preload("res://scenes/world_map.tscn")
const Assertions := preload("res://tests/assertions.gd")

const WORLD_HALF_EXTENT := 128.0
const TOWN_SPACING_MIN := 140.0
const TOWN_SPACING_MAX := 175.0
const HUB_CLEARANCE := 85.0
const HOUSE_ROAD_MARGIN := 2.0
const FOREST_ROAD_CLEARANCE := 4.0
const FOREST_INSTANCE_FLOOR := 600
const INSTANCE_BUDGET := 4500
const GROUND_PLANE_SIZE := Vector2(256.0, 256.0)
const TOWN_NAMES := ["Northmere", "Westbrook", "Eastholm"]
const GROUP_NAMES := ["Towns", "Forests", "Scatter", "Roads"]

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _map: Node3D = null
var _spokes: Array = []
var _houses: Array = []


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	_map = WorldMapScene.instantiate() as Node3D
	_world.add_child(_map)

	await get_tree().process_frame
	await get_tree().process_frame

	print("== world map: three towns, three spokes, one budget ==")
	_test_the_groups_exist()
	_test_town_centres_are_spread()
	_test_everything_stays_inside_the_world()
	_read_spokes()
	_collect_houses()
	_test_no_two_houses_overlap()
	_test_no_house_sits_on_a_road()
	_test_forests_keep_off_the_roads()
	_test_the_instance_budget_holds()
	_test_the_ground_covers_the_world()

	print(
		"WORLD MAP RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_the_groups_exist() -> void:
	for group_name in GROUP_NAMES:
		_check(
			_map.get_node_or_null(group_name) != null,
			"the map authors a %s group" % group_name,
		)


func _test_town_centres_are_spread() -> void:
	var towns := _map.get_node_or_null("Towns")
	if towns == null:
		return
	var markers := towns.find_children("Center", "Marker3D", true, false)
	_check(
		markers.size() == 3,
		"holding exactly three Center markers, one per town, got %d" % markers.size(),
	)

	var centres := {}
	for town_name in TOWN_NAMES:
		var marker := _map.get_node_or_null("Towns/%s/Center" % town_name) as Marker3D
		_check(marker != null, "Towns/%s/Center is a Marker3D" % town_name)
		if marker != null:
			centres[town_name] = Vector2(marker.global_position.x, marker.global_position.z)

	for i in TOWN_NAMES.size():
		for j in range(i + 1, TOWN_NAMES.size()):
			var a: String = TOWN_NAMES[i]
			var b: String = TOWN_NAMES[j]
			if not centres.has(a) or not centres.has(b):
				continue
			var gap: float = (centres[a] as Vector2).distance_to(centres[b] as Vector2)
			_check(
				gap >= TOWN_SPACING_MIN and gap <= TOWN_SPACING_MAX,
				"%s and %s stand %.2f u apart, inside the [%.0f, %.0f] u band"
					% [a, b, gap, TOWN_SPACING_MIN, TOWN_SPACING_MAX],
			)

	var hub := _map.get_node_or_null("Roads/Hub") as Marker3D
	_check(hub != null, "Roads/Hub is a Marker3D")
	if hub == null:
		return
	var hub_xz := Vector2(hub.global_position.x, hub.global_position.z)
	for town_name in TOWN_NAMES:
		if not centres.has(town_name):
			continue
		var reach: float = (centres[town_name] as Vector2).distance_to(hub_xz)
		_check(
			reach >= HUB_CLEARANCE,
			"%s lies %.2f u from the hub, a walk of at least %.0f u" % [town_name, reach, HUB_CLEARANCE],
		)


func _test_everything_stays_inside_the_world() -> void:
	for group_name in GROUP_NAMES:
		var group := _map.get_node_or_null(group_name)
		if group == null:
			continue
		var counted := 0
		var offender := ""
		var at := Vector3.ZERO
		for node in group.find_children("*", "Node3D", true, false):
			counted += 1
			var here := (node as Node3D).global_position
			if absf(here.x) > WORLD_HALF_EXTENT or absf(here.z) > WORLD_HALF_EXTENT:
				offender = str(_map.get_path_to(node))
				at = here
				break
		var message := (
			"all %d Node3D under %s sit inside the +/-%.0f u world square"
			% [counted, group_name, WORLD_HALF_EXTENT]
		)
		if counted == 0:
			message = "%s holds no Node3D at all, so its bounds check would be vacuous" % group_name
		elif offender != "":
			message = (
				"%s sits at (%.2f, %.2f), outside the +/-%.0f u world square"
				% [offender, at.x, at.z, WORLD_HALF_EXTENT]
			)
		_check(counted > 0 and offender == "", message)


func _read_spokes() -> void:
	var roads := _map.get_node_or_null("Roads")
	if roads == null:
		return
	_check(roads.has_meta("spokes"), "Roads carries the metadata/spokes centrelines")
	if not roads.has_meta("spokes"):
		return
	var raw = roads.get_meta("spokes")
	var shape := "spokes is an Array of centrelines"
	if not (raw is Array):
		shape = "spokes is an Array of centrelines, got variant type %d" % typeof(raw)
	_check(raw is Array, shape)
	if not (raw is Array):
		return
	var lines: Array = raw
	_check(lines.size() == 3, "holding one centreline per town, got %d" % lines.size())
	var malformed := 0
	for line in lines:
		if line is PackedVector2Array and (line as PackedVector2Array).size() >= 2:
			_spokes.append(line)
		else:
			malformed += 1
	_check(
		malformed == 0,
		"and every centreline is a PackedVector2Array of two points or more, %d were not" % malformed,
	)


func _collect_houses() -> void:
	for town_name in TOWN_NAMES:
		var town := _map.get_node_or_null("Towns/%s" % town_name)
		_check(town != null, "Towns/%s is a group of its own" % town_name)
		if town == null:
			continue
		var counted := 0
		var malformed := 0
		for node in town.find_children("House*", "Node3D", true, false):
			var house := node as Node3D
			if not house.has_meta("footprint"):
				continue
			var raw = house.get_meta("footprint")
			if not (raw is Vector2):
				malformed += 1
				continue
			var footprint: Vector2 = raw
			counted += 1
			_houses.append({
				"path": str(_map.get_path_to(house)),
				"centre": Vector2(house.global_position.x, house.global_position.z),
				"half": footprint * 0.5,
				"footprint": footprint,
				"yaw": house.global_transform.basis.get_euler().y,
			})
		_check(counted > 0, "%s holds %d House nodes carrying a Vector2 footprint" % [town_name, counted])
		_check(malformed == 0, "and %d of its House footprints are not a Vector2" % malformed)


func _test_no_two_houses_overlap() -> void:
	if _houses.is_empty():
		return
	var overlaps := 0
	var worst_pair := ""
	var worst_depth := 0.0
	for i in _houses.size():
		for j in range(i + 1, _houses.size()):
			var depth := _rect_overlap_depth(_houses[i], _houses[j])
			if depth <= 0.0:
				continue
			overlaps += 1
			if depth > worst_depth:
				worst_depth = depth
				worst_pair = "%s and %s" % [_houses[i]["path"], _houses[j]["path"]]
	var pairs := _houses.size() * (_houses.size() - 1) / 2
	var message := "no two of the %d house footprints overlap, across %d pairs" % [_houses.size(), pairs]
	if overlaps > 0:
		message = (
			"%s overlap by %.3f u on their tightest separating axis, and %d pair(s) overlap in all"
			% [worst_pair, worst_depth, overlaps]
		)
	_check(overlaps == 0, message)


func _test_no_house_sits_on_a_road() -> void:
	if _spokes.is_empty() or _houses.is_empty():
		return
	var breaches := 0
	var tightest_slack := INF
	var tightest_path := ""
	var tightest_gap := 0.0
	var tightest_needed := 0.0
	for house in _houses:
		var footprint: Vector2 = house["footprint"]
		var needed := 0.5 * sqrt(footprint.x * footprint.x + footprint.y * footprint.y) + HOUSE_ROAD_MARGIN
		for spoke in _spokes:
			var gap := _point_to_polyline(house["centre"], spoke)
			if gap < needed:
				breaches += 1
			var slack := gap - needed
			if slack < tightest_slack:
				tightest_slack = slack
				tightest_path = house["path"]
				tightest_gap = gap
				tightest_needed = needed
	var message := (
		"every house clears all three spokes, the tightest being %s at %.2f u against the %.2f u it needs"
		% [tightest_path, tightest_gap, tightest_needed]
	)
	if breaches > 0:
		message = (
			"%s stands %.2f u from a spoke centreline, short of the %.2f u its footprint needs, and %d house-spoke pair(s) breach in all"
			% [tightest_path, tightest_gap, tightest_needed, breaches]
		)
	_check(breaches == 0, message)


func _test_forests_keep_off_the_roads() -> void:
	var forests := _map.get_node_or_null("Forests")
	if forests == null:
		return
	var instances := 0
	var breaches := 0
	var tightest := INF
	var tightest_path := ""
	for node in forests.find_children("*", "Node3D", true, false):
		var tree := node as Node3D
		if tree.scene_file_path.is_empty():
			continue
		instances += 1
		if _spokes.is_empty():
			continue
		var here := Vector2(tree.global_position.x, tree.global_position.z)
		var gap := INF
		for spoke in _spokes:
			gap = minf(gap, _point_to_polyline(here, spoke))
		if gap < FOREST_ROAD_CLEARANCE:
			breaches += 1
		if gap < tightest:
			tightest = gap
			tightest_path = str(_map.get_path_to(tree))
	if not _spokes.is_empty():
		var message := (
			"all %d instanced nodes under Forests keep off the %.1f u road corridor, the closest being %s at %.2f u"
			% [instances, FOREST_ROAD_CLEARANCE, tightest_path, tightest]
		)
		if breaches > 0:
			message = (
				"%s stands %.2f u from a spoke centreline, inside the %.1f u road corridor, and %d instance(s) breach in all"
				% [tightest_path, tightest, FOREST_ROAD_CLEARANCE, breaches]
			)
		_check(breaches == 0, message)
	_check(
		instances >= FOREST_INSTANCE_FLOOR,
		"Forests instances %d scenes, at least the %d it takes to read as woodland"
			% [instances, FOREST_INSTANCE_FLOOR],
	)


func _test_the_instance_budget_holds() -> void:
	var total := 0
	var per_group := PackedStringArray()
	for group_name in GROUP_NAMES:
		var group := _map.get_node_or_null(group_name)
		if group == null:
			continue
		var counted := 0
		for node in group.find_children("*", "", true, false):
			if not (node as Node).scene_file_path.is_empty():
				counted += 1
		total += counted
		per_group.append("%s %d" % [group_name, counted])
	_check(
		total <= INSTANCE_BUDGET,
		"the map instances %d scenes against the %d budget (%s)"
			% [total, INSTANCE_BUDGET, ", ".join(per_group)],
	)


func _test_the_ground_covers_the_world() -> void:
	var ground := _map.get_node_or_null("Ground/Mesh") as MeshInstance3D
	_check(ground != null, "Ground/Mesh is a MeshInstance3D")
	if ground == null:
		return
	var plane := ground.mesh as PlaneMesh
	_check(plane != null, "drawing a PlaneMesh")
	if plane == null:
		return
	_check(
		plane.size.is_equal_approx(GROUND_PLANE_SIZE),
		"of %.0f x %.0f metres, covering the whole %.0f u world square"
			% [plane.size.x, plane.size.y, WORLD_HALF_EXTENT * 2.0],
	)


static func _rect_overlap_depth(a: Dictionary, b: Dictionary) -> float:
	var axes := [
		_local_x(a["yaw"]),
		_local_z(a["yaw"]),
		_local_x(b["yaw"]),
		_local_z(b["yaw"]),
	]
	var offset: Vector2 = (b["centre"] as Vector2) - (a["centre"] as Vector2)
	var depth := INF
	for axis in axes:
		var gap: float = (
			absf(offset.dot(axis)) - _projection_radius(a, axis) - _projection_radius(b, axis)
		)
		if gap > 0.0:
			return -gap
		depth = minf(depth, -gap)
	return depth


static func _projection_radius(rect: Dictionary, axis: Vector2) -> float:
	var half: Vector2 = rect["half"]
	var yaw: float = rect["yaw"]
	return half.x * absf(axis.dot(_local_x(yaw))) + half.y * absf(axis.dot(_local_z(yaw)))


static func _local_x(yaw: float) -> Vector2:
	return Vector2(cos(yaw), -sin(yaw))


static func _local_z(yaw: float) -> Vector2:
	return Vector2(sin(yaw), cos(yaw))


static func _point_to_polyline(point: Vector2, line: PackedVector2Array) -> float:
	if line.is_empty():
		return INF
	if line.size() == 1:
		return point.distance_to(line[0])
	var best := INF
	for i in range(line.size() - 1):
		best = minf(best, _point_to_segment(point, line[i], line[i + 1]))
	return best


static func _point_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var span := b - a
	var span_squared := span.length_squared()
	if span_squared <= 0.0:
		return point.distance_to(a)
	var along := clampf((point - a).dot(span) / span_squared, 0.0, 1.0)
	return point.distance_to(a + span * along)


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
