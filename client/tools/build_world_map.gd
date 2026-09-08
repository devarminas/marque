extends SceneTree


const WORLD_PATH := "res://scenes/world_map.tscn"
const VILLAGE_DIR := "res://assets/quaternius/village/"
const NATURE_DIR := "res://assets/quaternius/nature/"
const GRASS_SHADER := "res://materials/ground_grass.gdshader"

const MODULE := 2.0
const STOREY := 3.0
const HALF_EXTENT := 128.0
const SEED := 20260908

const HUB := Vector2(0.0, 10.0)
const TOWN_RADIUS := 30.0
const PLAZA_HALF := 6.0
const HUB_HALF := 5.0
const TILE := 2.0
const ROAD_WIDTH := 4.0
const ROAD_Y := 0.03
const PAVING_Y := 0.05
const ROAD_WOBBLE := 3.0
const ROAD_ALBEDO := "Color(0.45, 0.36, 0.25, 1)"
const NODE_BUDGET := 4500
const FOREST_CELL := 5.5
const FOREST_JITTER := 2.2
const FOREST_ROAD_CLEARANCE := 5.0
const FOREST_SCALE_RANGE := Vector2(0.85, 1.15)
const WORLD_MARGIN := 3.0
const SCATTER_TOWN_CLEARANCE := 26.0
const SCATTER_ROAD_CLEARANCE := 3.0
const TRAVEL_ROAD_REACH := 25.0
const TRAVEL_TOWN_REACH := 40.0
const RIM_THRESHOLD := 100.0

enum Style { PLASTER, BRICK }
enum Side { NORTH, EAST, SOUTH, WEST }
enum Zone { RIM, WOODS, COPSE }
enum Allow { ANYWHERE, OFF_FOREST, NEAR_TRAVEL }

const PINES := ["Pine_1", "Pine_2", "Pine_3", "Pine_4", "Pine_5"]
const BROADLEAVES := ["CommonTree_1", "CommonTree_2", "CommonTree_3", "CommonTree_4", "CommonTree_5"]
const ROCK_PATHS := [
	"RockPath_Round_Small_1", "RockPath_Round_Thin", "RockPath_Round_Wide", "RockPath_Square_Wide"
]
const PEBBLES := ["Pebble_Round_1", "Pebble_Round_2", "Pebble_Square_1"]
const TUFTS := ["Grass_Wispy_Short", "Grass_Wispy_Tall", "Grass_Common_Tall"]
const BUSHES := ["Bush_Common", "Bush_Common_Flowers"]
const FLOWER_GROUPS := ["Flower_3_Group", "Flower_4_Group"]
const BOULDERS := ["Rock_Medium_1", "Rock_Medium_2", "Rock_Medium_3"]
const DOORSTEP_PIECES := ["Bush_Common_Flowers", "Flower_4_Group"]

const WALL_STRAIGHT := {Style.PLASTER: "Wall_Plaster_Straight", Style.BRICK: "Wall_UnevenBrick_Straight"}
const WALL_DOOR := {Style.PLASTER: "Wall_Plaster_Door_Flat", Style.BRICK: "Wall_UnevenBrick_Door_Flat"}
const WALL_WINDOW_WIDE := {
	Style.PLASTER: "Wall_Plaster_Window_Wide_Flat", Style.BRICK: "Wall_UnevenBrick_Window_Wide_Flat"
}
const WALL_WINDOW_THIN := {
	Style.PLASTER: "Wall_Plaster_Window_Thin_Round", Style.BRICK: "Wall_UnevenBrick_Window_Thin_Round"
}
const CORNER := {Style.PLASTER: "Corner_Exterior_Wood", Style.BRICK: "Corner_Exterior_Brick"}
const FLOOR := {Style.PLASTER: "Floor_WoodDark", Style.BRICK: "Floor_UnevenBrick"}
const ROOF_RIDGE := {4: 3.73, 6: 4.89, 8: 6.0}
const SIDE_YAW := {Side.NORTH: 0.0, Side.SOUTH: PI, Side.EAST: -PI / 2.0, Side.WEST: PI / 2.0}
const SIDE_NORMAL := {
	Side.NORTH: Vector3(0, 0, -1),
	Side.SOUTH: Vector3(0, 0, 1),
	Side.EAST: Vector3(1, 0, 0),
	Side.WEST: Vector3(-1, 0, 0),
}
const DOOR_HINGE_OFFSET := -0.51
const WINDOW_CHANCE := 0.65


class SceneWriter:
	var instance_count := 0
	var _ext_ids: Dictionary = {}
	var _ext_lines: Array[String] = []
	var _sub_lines: Array[String] = []
	var _node_lines: Array[String] = []
	var _name_counts: Dictionary = {}

	func ext(path: String, type: String) -> String:
		if not _ext_ids.has(path):
			var id := "%d_%s" % [_ext_ids.size() + 1, path.get_file().get_basename().to_lower()]
			_ext_ids[path] = id
			_ext_lines.append('[ext_resource type="%s" path="%s" id="%s"]' % [type, path, id])
		return 'ExtResource("%s")' % _ext_ids[path]

	func sub(type: String, id: String, props: Dictionary) -> String:
		_sub_lines.append('[sub_resource type="%s" id="%s"]' % [type, id])
		for key in props:
			_sub_lines.append("%s = %s" % [key, props[key]])
		_sub_lines.append("")
		return 'SubResource("%s")' % id

	func root(name: String, type: String, props: Dictionary = {}) -> void:
		_node_lines.append('[node name="%s" type="%s"]' % [name, type])
		_props(props)

	func node(parent: String, name: String, type: String, props: Dictionary = {}) -> String:
		var unique := _unique(parent, name)
		_node_lines.append('[node name="%s" type="%s" parent="%s"]' % [unique, type, parent])
		_props(props)
		return _child_path(parent, unique)

	func instance(parent: String, name: String, scene: String, xform: Transform3D) -> String:
		instance_count += 1
		var unique := _unique(parent, name)
		_node_lines.append(
			'[node name="%s" parent="%s" instance=%s]' % [unique, parent, ext(scene, "PackedScene")]
		)
		if not xform.is_equal_approx(Transform3D.IDENTITY):
			_node_lines.append("transform = " + var_to_str(xform))
		_node_lines.append("")
		return _child_path(parent, unique)

	func save(path: String) -> void:
		var steps := _ext_ids.size() + 1
		for line in _sub_lines:
			if line.begins_with("[sub_resource"):
				steps += 1
		var out := FileAccess.open(path, FileAccess.WRITE)
		out.store_line("[gd_scene load_steps=%d format=3]" % steps)
		out.store_line("")
		for line in _ext_lines:
			out.store_line(line)
		out.store_line("")
		for line in _sub_lines:
			out.store_line(line)
		for line in _node_lines:
			out.store_line(line)
		out.close()

	func _props(props: Dictionary) -> void:
		for key in props:
			_node_lines.append("%s = %s" % [key, props[key]])
		_node_lines.append("")

	func _unique(parent: String, name: String) -> String:
		var key := parent + "|" + name
		var count: int = _name_counts.get(key, 0)
		_name_counts[key] = count + 1
		return name if count == 0 else "%s%d" % [name, count + 1]

	static func _child_path(parent: String, name: String) -> String:
		return name if parent == "." else parent + "/" + name


static func village(piece: String) -> String:
	return VILLAGE_DIR + piece + ".gltf"


static func nature(piece: String) -> String:
	return NATURE_DIR + piece + ".gltf"


static func yaw_at(yaw: float, origin: Vector3) -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)), origin)


static func house_spec(
	width_modules: int,
	length_modules: int,
	storeys: int,
	ground: int,
	upper: int,
	door: int,
	tower: bool = false,
	chimney: bool = true
) -> Dictionary:
	return {
		"w": width_modules,
		"l": length_modules,
		"storeys": storeys,
		"ground": ground,
		"upper": upper,
		"door": door,
		"tower": tower,
		"chimney": chimney,
	}


static func add_house(
	writer: SceneWriter, parent: String, spec: Dictionary, at: Transform3D, rng: RandomNumberGenerator
) -> String:
	var w: int = spec["w"]
	var l: int = spec["l"]
	var width := w * MODULE
	var length := l * MODULE
	var house := writer.node(
		parent,
		"House",
		"Node3D",
		{"transform": var_to_str(at), "metadata/footprint": var_to_str(Vector2(width, length))},
	)
	var storeys: int = spec["storeys"]
	var floor_style: int = spec["ground"]
	for ix in w:
		for iz in l:
			var origin := Vector3(
				-width / 2.0 + 1.0 + ix * MODULE, 0.0, -length / 2.0 + 1.0 + iz * MODULE
			)
			writer.instance(house, "Floor", village(FLOOR[floor_style]), Transform3D(Basis.IDENTITY, origin))
	for storey in storeys:
		var style: int = spec["ground"] if storey == 0 else spec["upper"]
		var y := storey * STOREY
		for side in [Side.NORTH, Side.EAST, Side.SOUTH, Side.WEST]:
			var along: int = w if side in [Side.NORTH, Side.SOUTH] else l
			var normal: Vector3 = SIDE_NORMAL[side]
			var tangent := Vector3(-normal.z, 0.0, normal.x)
			var yaw: float = SIDE_YAW[side]
			var reach := width / 2.0 if normal.x != 0.0 else length / 2.0
			for i in along:
				var offset := -along * MODULE / 2.0 + 1.0 + i * MODULE
				var origin := normal * reach + tangent * offset
				origin.y = y
				var xform := yaw_at(yaw, origin)
				var is_door: bool = storey == 0 and side == spec["door"] and i == along / 2
				if is_door:
					writer.instance(house, "DoorWall", village(WALL_DOOR[style]), xform)
					writer.instance(house, "DoorFrame", village("DoorFrame_Flat_WoodDark"), xform)
					var ajar := rng.randf_range(0.0, 0.35) if rng.randf() < 0.3 else 0.0
					var door_local := yaw_at(ajar, Vector3(DOOR_HINGE_OFFSET, 0.0, 0.0))
					writer.instance(house, "Door", village("Door_1_Flat"), xform * door_local)
				elif rng.randf() < WINDOW_CHANCE:
					if rng.randf() < 0.7:
						writer.instance(house, "WindowWall", village(WALL_WINDOW_WIDE[style]), xform)
						writer.instance(house, "Window", village("Window_Wide_Flat1"), xform)
					else:
						writer.instance(house, "WindowWall", village(WALL_WINDOW_THIN[style]), xform)
						writer.instance(house, "Window", village("Window_Thin_Round1"), xform)
				else:
					writer.instance(house, "Wall", village(WALL_STRAIGHT[style]), xform)
		for corner in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)]:
			var origin := Vector3(corner.x * width / 2.0, y, corner.z * length / 2.0)
			writer.instance(house, "Corner", village(CORNER[style]), Transform3D(Basis.IDENTITY, origin))
	var roof_y := storeys * STOREY
	var roof_origin := Transform3D(Basis.IDENTITY, Vector3(0.0, roof_y, 0.0))
	if spec["tower"]:
		writer.instance(house, "Roof", village("Roof_Tower_RoundTiles"), roof_origin)
	else:
		var roof_piece := "Roof_RoundTiles_%dx%d" % [int(width), int(length)]
		writer.instance(house, "Roof", village(roof_piece), roof_origin)
		var gable := "Roof_Front_Brick%d" % int(width)
		writer.instance(house, "GableNorth", village(gable), yaw_at(0.0, Vector3(0.0, roof_y, -length / 2.0)))
		writer.instance(house, "GableSouth", village(gable), yaw_at(PI, Vector3(0.0, roof_y, length / 2.0)))
		if spec["chimney"]:
			var ridge: float = ROOF_RIDGE[int(width)]
			var chimney_origin := Vector3(width / 4.0, roof_y + ridge * 0.5 - 0.6, length / 4.0)
			writer.instance(house, "Chimney", village("Prop_Chimney"), Transform3D(Basis.IDENTITY, chimney_origin))
	return house


static func add_fence_run(
	writer: SceneWriter,
	parent: String,
	from: Vector3,
	to: Vector3,
	piece: String = "Prop_WoodenFence_Single"
) -> void:
	var span := to - from
	var count := int(round(span.length() / MODULE))
	if count == 0:
		return
	var step := span / count
	var yaw := atan2(-step.z, step.x)
	for i in count:
		writer.instance(parent, "Fence", village(piece), yaw_at(yaw, from + step * (i + 0.5)))


func _initialize() -> void:
	quit(_write_world())


static func lot(offset: Vector2, yaw: float, spec: Dictionary) -> Dictionary:
	return {"offset": offset, "yaw": yaw, "house": spec}


static func town_table() -> Array:
	return [
		{
			"name": "Northmere",
			"center": Vector2(0.0, -82.0),
			"lots": [
				lot(Vector2(-5.0, -14.0), 0.0, house_spec(3, 4, 2, Style.BRICK, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(5.5, -13.0), 0.0, house_spec(3, 3, 1, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(-14.0, -4.0), PI / 2.0, house_spec(3, 4, 1, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(-13.0, 5.0), PI / 2.0, house_spec(2, 3, 2, Style.BRICK, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(12.0, -5.0), -PI / 2.0, house_spec(2, 2, 3, Style.BRICK, Style.BRICK, Side.SOUTH, true)),
				lot(Vector2(14.0, 4.0), -PI / 2.0, house_spec(3, 4, 1, Style.BRICK, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(-10.0, 14.0), PI, house_spec(3, 4, 2, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(10.0, 13.0), PI, house_spec(3, 3, 1, Style.BRICK, Style.PLASTER, Side.SOUTH)),
			],
			"fences": [
				[Vector2(-8.0, -18.5), Vector2(-8.0, -24.5)],
				[Vector2(-8.0, -24.5), Vector2(0.0, -24.5)],
			],
			"wagon": {"at": Vector2(-4.0, 8.0), "yaw": PI / 2.0},
			"crates": [Vector2(-8.0, 6.0), Vector2(-8.9, 7.3), Vector2(-7.2, 7.9)],
			"trees": [Vector2(-8.5, 1.0), Vector2(8.0, -1.0), Vector2(0.0, -21.0)],
		},
		{
			"name": "Westbrook",
			"center": Vector2(-78.0, 56.0),
			"lots": [
				lot(Vector2(-5.0, -14.0), 0.0, house_spec(3, 4, 2, Style.BRICK, Style.BRICK, Side.SOUTH)),
				lot(Vector2(5.0, -12.0), 0.0, house_spec(2, 2, 1, Style.BRICK, Style.BRICK, Side.SOUTH)),
				lot(Vector2(-15.0, -4.0), PI / 2.0, house_spec(3, 5, 1, Style.BRICK, Style.BRICK, Side.SOUTH)),
				lot(Vector2(-13.0, 5.0), PI / 2.0, house_spec(2, 3, 2, Style.BRICK, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(14.0, -4.0), -PI / 2.0, house_spec(3, 4, 1, Style.BRICK, Style.BRICK, Side.SOUTH)),
				lot(Vector2(13.0, 5.0), -PI / 2.0, house_spec(2, 3, 1, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(-10.0, 14.0), PI, house_spec(3, 4, 2, Style.BRICK, Style.BRICK, Side.SOUTH)),
			],
			"fences": [
				[Vector2(-20.5, -1.0), Vector2(-26.5, -1.0)],
				[Vector2(-26.5, -1.0), Vector2(-26.5, -8.0)],
			],
			"wagon": {"at": Vector2(-4.0, 8.0), "yaw": PI / 2.0},
			"crates": [Vector2(-8.0, 6.2), Vector2(-8.9, 7.4), Vector2(-7.2, 8.0)],
			"trees": [Vector2(-8.5, 1.0), Vector2(8.5, 0.0), Vector2(0.0, -20.0)],
		},
		{
			"name": "Eastholm",
			"center": Vector2(78.0, 56.0),
			"lots": [
				lot(Vector2(-5.0, -15.0), 0.0, house_spec(4, 5, 2, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(6.0, -13.0), 0.0, house_spec(3, 3, 1, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(-14.0, -4.0), PI / 2.0, house_spec(3, 4, 1, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(-12.0, 5.0), PI / 2.0, house_spec(2, 2, 2, Style.PLASTER, Style.BRICK, Side.SOUTH)),
				lot(Vector2(13.0, -4.0), -PI / 2.0, house_spec(2, 3, 1, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(14.0, 4.0), -PI / 2.0, house_spec(3, 4, 1, Style.BRICK, Style.PLASTER, Side.SOUTH)),
				lot(Vector2(10.0, 14.0), PI, house_spec(3, 4, 2, Style.PLASTER, Style.PLASTER, Side.SOUTH)),
			],
			"fences": [
				[Vector2(7.0, 18.5), Vector2(7.0, 24.5)],
				[Vector2(7.0, 24.5), Vector2(14.0, 24.5)],
			],
			"wagon": {"at": Vector2(4.0, 8.0), "yaw": -PI / 2.0},
			"crates": [Vector2(8.0, 6.2), Vector2(8.9, 7.4), Vector2(7.2, 8.0)],
			"trees": [Vector2(-8.5, 1.0), Vector2(8.5, -0.5), Vector2(0.0, -22.0)],
		},
	]


static func region_table() -> Array:
	return [
		{"name": "Rim", "kind": Zone.RIM, "center": Vector2.ZERO, "radii": Vector2.ONE, "chance": 0.85},
		{
			"name": "NorthwestWoods",
			"kind": Zone.WOODS,
			"center": Vector2(-60.0, -45.0),
			"radii": Vector2(45.0, 35.0),
			"chance": 0.7,
		},
		{
			"name": "NortheastWoods",
			"kind": Zone.WOODS,
			"center": Vector2(62.0, -40.0),
			"radii": Vector2(42.0, 34.0),
			"chance": 0.7,
		},
		{
			"name": "SouthWoods",
			"kind": Zone.WOODS,
			"center": Vector2(0.0, 95.0),
			"radii": Vector2(60.0, 26.0),
			"chance": 0.7,
		},
		{"name": "Copse1", "kind": Zone.COPSE, "center": Vector2(-30.0, 5.0), "radii": Vector2(11.0, 11.0), "chance": 0.9},
		{"name": "Copse2", "kind": Zone.COPSE, "center": Vector2(28.0, 18.0), "radii": Vector2(9.0, 9.0), "chance": 0.9},
		{"name": "Copse3", "kind": Zone.COPSE, "center": Vector2(-5.0, -40.0), "radii": Vector2(12.0, 12.0), "chance": 0.9},
		{"name": "Copse4", "kind": Zone.COPSE, "center": Vector2(40.0, 62.0), "radii": Vector2(8.0, 8.0), "chance": 0.9},
		{"name": "Copse5", "kind": Zone.COPSE, "center": Vector2(-42.0, 70.0), "radii": Vector2(10.0, 10.0), "chance": 0.9},
	]


static func scatter_table() -> Array:
	return [
		{"group": "Bushes", "pieces": BUSHES, "cell": 11.0, "chance": 0.35, "allow": Allow.ANYWHERE},
		{"group": "Flowers", "pieces": FLOWER_GROUPS, "cell": 9.0, "chance": 0.3, "allow": Allow.OFF_FOREST},
		{"group": "Rocks", "pieces": BOULDERS, "cell": 16.0, "chance": 0.12, "allow": Allow.ANYWHERE},
		{"group": "Grass", "pieces": TUFTS, "cell": 6.0, "chance": 0.5, "allow": Allow.NEAR_TRAVEL},
	]


static func flat(p: Vector2, y: float = 0.0) -> Vector3:
	return Vector3(p.x, y, p.y)


static func heading(direction: Vector2) -> float:
	return atan2(direction.x, direction.y)


static func point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var span := b - a
	var square := span.length_squared()
	if square <= 0.0:
		return p.distance_to(a)
	return p.distance_to(a + span * clampf((p - a).dot(span) / square, 0.0, 1.0))


static func point_to_polyline(p: Vector2, line: PackedVector2Array) -> float:
	var best := INF
	for i in line.size() - 1:
		best = minf(best, point_to_segment(p, line[i], line[i + 1]))
	return best


static func inside_world(p: Vector2, margin: float) -> bool:
	var limit := HALF_EXTENT - margin
	return absf(p.x) <= limit and absf(p.y) <= limit


static func outside_towns(p: Vector2, towns: Array, radius: float) -> bool:
	for town in towns:
		if p.distance_to(town["center"]) < radius:
			return false
	return true


static func road_clearance(p: Vector2, spokes: Array, minimum: float) -> bool:
	for line in spokes:
		if point_to_polyline(p, line) < minimum:
			return false
	return true


static func inside_region(p: Vector2, region: Dictionary) -> bool:
	if region["kind"] == Zone.RIM:
		return absf(p.x) > RIM_THRESHOLD or absf(p.y) > RIM_THRESHOLD
	var offset: Vector2 = (p - region["center"]) / region["radii"]
	return offset.length_squared() <= 1.0


static func scatter_allows(
	p: Vector2, allow: Allow, regions: Array, towns: Array, spokes: Array
) -> bool:
	match allow:
		Allow.OFF_FOREST:
			for region in regions:
				if inside_region(p, region):
					return false
			return true
		Allow.NEAR_TRAVEL:
			for line in spokes:
				if point_to_polyline(p, line) <= TRAVEL_ROAD_REACH:
					return true
			for town in towns:
				if p.distance_to(town["center"]) <= TRAVEL_TOWN_REACH:
					return true
			return false
	return true


static func spoke_line(rng: RandomNumberGenerator, center: Vector2) -> PackedVector2Array:
	var toward := (HUB - center).normalized()
	var start := center + toward * PLAZA_HALF
	var span := HUB - start
	var length := span.length()
	var direction := span / length
	var lateral := Vector2(-direction.y, direction.x)
	var interior := 2 + rng.randi() % 2
	var line := PackedVector2Array([start])
	for i in interior:
		var along := length * float(i + 1) / float(interior + 1)
		var wobble := rng.randf_range(-ROAD_WOBBLE, ROAD_WOBBLE)
		line.append(start + direction * along + lateral * wobble)
	line.append(HUB)
	return line


static func walk_line(line: PackedVector2Array, spacing: float, start: float) -> Array:
	var stations := []
	var travelled := start
	var consumed := 0.0
	for i in line.size() - 1:
		var a := line[i]
		var span := line[i + 1] - a
		var length := span.length()
		if length <= 0.0:
			continue
		var direction := span / length
		while travelled < consumed + length:
			stations.append({"at": a + direction * (travelled - consumed), "dir": direction})
			travelled += spacing
		consumed += length
	return stations


func _add_lighting(writer: SceneWriter) -> void:
	var sky_material := writer.sub(
		"ProceduralSkyMaterial",
		"ProceduralSkyMaterial_sky",
		{
			"sky_top_color": "Color(0.38, 0.55, 0.85, 1)",
			"sky_horizon_color": "Color(0.72, 0.8, 0.9, 1)",
			"ground_bottom_color": "Color(0.2, 0.25, 0.2, 1)",
			"ground_horizon_color": "Color(0.6, 0.65, 0.6, 1)",
		}
	)
	var sky := writer.sub("Sky", "Sky_world", {"sky_material": sky_material})
	var environment := writer.sub(
		"Environment",
		"Environment_world",
		{
			"background_mode": "2",
			"sky": sky,
			"ambient_light_source": "3",
			"ambient_light_energy": "0.6",
		}
	)
	writer.node(".", "WorldEnvironment", "WorldEnvironment", {"environment": environment})
	var sun := Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-50.0), deg_to_rad(-35.0), 0.0)), Vector3(0.0, 12.0, 0.0)
	)
	writer.node(
		".",
		"Sun",
		"DirectionalLight3D",
		{"transform": var_to_str(sun), "light_energy": "1.2", "shadow_enabled": "true"}
	)


func _add_ground(writer: SceneWriter) -> void:
	var extent := HALF_EXTENT * 2.0
	var material := writer.sub(
		"ShaderMaterial", "ShaderMaterial_ground", {"shader": writer.ext(GRASS_SHADER, "Shader")}
	)
	var mesh := writer.sub(
		"PlaneMesh", "PlaneMesh_ground", {"size": var_to_str(Vector2(extent, extent))}
	)
	var shape := writer.sub(
		"BoxShape3D", "BoxShape3D_ground", {"size": var_to_str(Vector3(extent, 1.0, extent))}
	)
	writer.node(".", "Ground", "StaticBody3D", {"collision_mask": "0"})
	writer.node("Ground", "Mesh", "MeshInstance3D", {"material_override": material, "mesh": mesh})
	writer.node(
		"Ground",
		"CollisionShape3D",
		"CollisionShape3D",
		{
			"transform": var_to_str(Transform3D(Basis.IDENTITY, Vector3(0.0, -0.5, 0.0))),
			"shape": shape,
		}
	)


func _add_roads(
	writer: SceneWriter, rng: RandomNumberGenerator, towns: Array, spokes: Array
) -> void:
	writer.node(".", "Roads", "Node3D", {"metadata/spokes": var_to_str(spokes)})
	writer.node(
		"Roads", "Hub", "Marker3D", {"transform": var_to_str(Transform3D(Basis.IDENTITY, flat(HUB)))}
	)
	var surface := writer.sub(
		"StandardMaterial3D",
		"StandardMaterial3D_road",
		{"albedo_color": ROAD_ALBEDO, "roughness": "1.0"}
	)
	var quad := writer.sub(
		"PlaneMesh", "PlaneMesh_road", {"material": surface, "size": var_to_str(Vector2.ONE)}
	)
	_add_hub_yard(writer, rng)
	for index in towns.size():
		var town: Dictionary = towns[index]
		var line: PackedVector2Array = spokes[index]
		var group := writer.node("Roads", town["name"], "Node3D")
		for i in line.size() - 1:
			var a := line[i]
			var span := line[i + 1] - a
			var length := span.length()
			var basis := Basis.from_euler(Vector3(0.0, heading(span / length), 0.0))
			basis *= Basis.from_scale(Vector3(ROAD_WIDTH, 1.0, length + ROAD_WIDTH))
			writer.node(
				group,
				"Segment",
				"MeshInstance3D",
				{
					"transform": var_to_str(Transform3D(basis, flat(a + span * 0.5, ROAD_Y))),
					"mesh": quad,
					"cast_shadow": "0",
				}
			)
		for station in walk_line(line, 5.0, 2.5):
			writer.instance(
				group,
				"PathTile",
				nature(ROCK_PATHS[rng.randi() % ROCK_PATHS.size()]),
				yaw_at(rng.randf_range(0.0, TAU), flat(station["at"], ROAD_Y))
			)
		var edge := ROAD_WIDTH / 2.0
		var flip := 1.0
		for station in walk_line(line, 3.0, 1.5):
			var side: Vector2 = Vector2(-station["dir"].y, station["dir"].x) * flip
			flip = -flip
			writer.instance(
				group,
				"Pebble",
				nature(PEBBLES[rng.randi() % PEBBLES.size()]),
				yaw_at(rng.randf_range(0.0, TAU), flat(station["at"] + side * (edge - 0.4), ROAD_Y))
			)
		for station in walk_line(line, 4.0, 2.0):
			var side := Vector2(-station["dir"].y, station["dir"].x)
			for direction in [side, -side]:
				writer.instance(
					group,
					"Tuft",
					nature(TUFTS[rng.randi() % TUFTS.size()]),
					yaw_at(rng.randf_range(0.0, TAU), flat(station["at"] + direction * (edge + 0.6)))
				)


func _add_hub_yard(writer: SceneWriter, rng: RandomNumberGenerator) -> void:
	var yard := writer.node(
		"Roads", "HubYard", "Node3D", {"transform": var_to_str(Transform3D(Basis.IDENTITY, flat(HUB)))}
	)
	var tiles := int(HUB_HALF * 2.0 / TILE)
	for ix in tiles:
		for iz in tiles:
			var origin := Vector3(
				-HUB_HALF + TILE / 2.0 + ix * TILE, PAVING_Y, -HUB_HALF + TILE / 2.0 + iz * TILE
			)
			writer.instance(yard, "Tile", village("Floor_Brick"), Transform3D(Basis.IDENTITY, origin))
	writer.instance(yard, "Wagon", village("Prop_Wagon"), yaw_at(1.9, Vector3(7.5, 0.0, -1.5)))
	for spot in [Vector2(-7.5, -1.5), Vector2(-8.3, -0.4), Vector2(-7.0, 0.6)]:
		writer.instance(
			yard, "Crate", village("Prop_Crate"), yaw_at(rng.randf_range(0.0, TAU), flat(spot))
		)
	for angle in [1.15, 2.0, 3.66, 5.77]:
		var at := Vector2(cos(angle), sin(angle)) * 12.0
		writer.instance(
			yard,
			"Tree",
			nature(BROADLEAVES[rng.randi() % BROADLEAVES.size()]),
			yaw_at(rng.randf_range(0.0, TAU), flat(at))
		)


func _add_towns(writer: SceneWriter, rng: RandomNumberGenerator, towns: Array) -> void:
	writer.node(".", "Towns", "Node3D")
	for town in towns:
		var center: Vector2 = town["center"]
		var yaw := heading((HUB - center).normalized())
		var group := writer.node(
			"Towns",
			town["name"],
			"Node3D",
			{"transform": var_to_str(yaw_at(yaw, flat(center))), "metadata/radius": "%.1f" % TOWN_RADIUS}
		)
		writer.node(group, "Center", "Marker3D")
		var plaza := writer.node(group, "Plaza", "Node3D")
		var tiles := int(PLAZA_HALF * 2.0 / TILE)
		for ix in tiles:
			for iz in tiles:
				var origin := Vector3(
					-PLAZA_HALF + TILE / 2.0 + ix * TILE, PAVING_Y, -PLAZA_HALF + TILE / 2.0 + iz * TILE
				)
				writer.instance(plaza, "Tile", village("Floor_Brick"), Transform3D(Basis.IDENTITY, origin))
		for index in town["lots"].size():
			var slot: Dictionary = town["lots"][index]
			var spec: Dictionary = slot["house"]
			var at := yaw_at(slot["yaw"], flat(slot["offset"]))
			add_house(writer, group, spec, at, rng)
			if index >= DOORSTEP_PIECES.size():
				continue
			var corner := Vector3(
				spec["w"] * MODULE / 2.0 + 0.9, 0.0, spec["l"] * MODULE / 2.0 + 0.9
			)
			writer.instance(
				group,
				"Doorstep",
				nature(DOORSTEP_PIECES[index]),
				at * yaw_at(rng.randf_range(0.0, TAU), corner)
			)
		for run in town["fences"]:
			add_fence_run(writer, group, flat(run[0]), flat(run[1]))
		var wagon: Dictionary = town["wagon"]
		writer.instance(group, "Wagon", village("Prop_Wagon"), yaw_at(wagon["yaw"], flat(wagon["at"])))
		for spot in town["crates"]:
			writer.instance(
				group, "Crate", village("Prop_Crate"), yaw_at(rng.randf_range(0.0, TAU), flat(spot))
			)
		for spot in town["trees"]:
			writer.instance(
				group,
				"Tree",
				nature(BROADLEAVES[rng.randi() % BROADLEAVES.size()]),
				yaw_at(rng.randf_range(0.0, TAU), flat(spot))
			)


func _add_forests(
	writer: SceneWriter, rng: RandomNumberGenerator, towns: Array, spokes: Array
) -> void:
	writer.node(".", "Forests", "Node3D")
	var steps := int(ceil(HALF_EXTENT * 2.0 / FOREST_CELL))
	var first := -HALF_EXTENT + FOREST_CELL / 2.0
	for region in region_table():
		var group := writer.node("Forests", region["name"], "Node3D")
		for ix in steps:
			for iz in steps:
				var p := Vector2(first + ix * FOREST_CELL, first + iz * FOREST_CELL)
				p.x += rng.randf_range(-FOREST_JITTER, FOREST_JITTER)
				p.y += rng.randf_range(-FOREST_JITTER, FOREST_JITTER)
				if rng.randf() > region["chance"]:
					continue
				if not inside_region(p, region):
					continue
				if not inside_world(p, WORLD_MARGIN):
					continue
				if not outside_towns(p, towns, TOWN_RADIUS):
					continue
				if not road_clearance(p, spokes, FOREST_ROAD_CLEARANCE):
					continue
				var species: Array = PINES if rng.randf() < (0.7 if p.y < -20.0 else 0.25) else BROADLEAVES
				var basis := Basis.from_euler(Vector3(0.0, rng.randf_range(0.0, TAU), 0.0))
				basis *= Basis.from_scale(
					Vector3.ONE * rng.randf_range(FOREST_SCALE_RANGE.x, FOREST_SCALE_RANGE.y)
				)
				writer.instance(
					group, "Tree", nature(species[rng.randi() % species.size()]), Transform3D(basis, flat(p))
				)


func _add_scatter(
	writer: SceneWriter, rng: RandomNumberGenerator, towns: Array, spokes: Array
) -> void:
	writer.node(".", "Scatter", "Node3D")
	var regions := region_table()
	for rule in scatter_table():
		var group := writer.node("Scatter", rule["group"], "Node3D")
		var cell: float = rule["cell"]
		var jitter := cell * 0.4
		var steps := int(ceil(HALF_EXTENT * 2.0 / cell))
		var first := -HALF_EXTENT + cell / 2.0
		var pieces: Array = rule["pieces"]
		for ix in steps:
			for iz in steps:
				var p := Vector2(first + ix * cell, first + iz * cell)
				p.x += rng.randf_range(-jitter, jitter)
				p.y += rng.randf_range(-jitter, jitter)
				if rng.randf() > rule["chance"]:
					continue
				if not inside_world(p, WORLD_MARGIN):
					continue
				if not outside_towns(p, towns, SCATTER_TOWN_CLEARANCE):
					continue
				if not road_clearance(p, spokes, SCATTER_ROAD_CLEARANCE):
					continue
				if not scatter_allows(p, rule["allow"], regions, towns, spokes):
					continue
				writer.instance(
					group,
					"Piece",
					nature(pieces[rng.randi() % pieces.size()]),
					yaw_at(rng.randf_range(0.0, TAU), flat(p))
				)


func _write_world() -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var writer := SceneWriter.new()
	var towns := town_table()
	var spokes := []
	for town in towns:
		spokes.append(spoke_line(rng, town["center"]))

	writer.root("WorldMap", "Node3D")
	_add_lighting(writer)
	_add_ground(writer)
	var counts := {}
	var marked := writer.instance_count
	_add_roads(writer, rng, towns, spokes)
	counts["Roads"] = writer.instance_count - marked
	marked = writer.instance_count
	_add_towns(writer, rng, towns)
	counts["Towns"] = writer.instance_count - marked
	marked = writer.instance_count
	_add_forests(writer, rng, towns, spokes)
	counts["Forests"] = writer.instance_count - marked
	marked = writer.instance_count
	_add_scatter(writer, rng, towns, spokes)
	counts["Scatter"] = writer.instance_count - marked

	for group in counts:
		print("%-8s %d" % [group, counts[group]])
	print("%-8s %d" % ["total", writer.instance_count])
	if writer.instance_count > NODE_BUDGET:
		push_error(
			"world map is %d instanced nodes, over the %d budget"
			% [writer.instance_count, NODE_BUDGET]
		)
		return 1
	writer.save(WORLD_PATH)
	print("wrote " + WORLD_PATH)
	return 0
