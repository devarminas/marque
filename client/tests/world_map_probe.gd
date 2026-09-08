extends Node3D


const SETTLE_FRAMES := 40
const MEASURE_FRAMES := 60
const AERIAL_SIZE := 262.0
const AERIAL_HEIGHT := 200.0
const TOWN_NAMES := ["Northmere", "Westbrook", "Eastholm"]
const TOWN_EYE_BACK := 13.0
const TOWN_EYE_UP := 5.0
const TOWN_AIM_AHEAD := 10.0
const TOWN_AIM_UP := 3.0
const ROOF_BOX_TIGHT := 40
const ROOF_BOX_WIDE := 120
const ROOF_MIN_FRACTION := 0.03
const HUB_BOX := 20
const HUB_MIN_FRACTION := 0.10
const ROAD_SAMPLE_OUT := 9.0
const SKY_BOX := 40
const SKY_AT := Vector2(20.0, 20.0)

@onready var _camera: Camera3D = $Camera
@onready var _map: Node3D = $WorldMap


func _ready() -> void:
	var prefix := "user://world_map"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--prefix" and i + 1 < args.size():
			prefix = args[i + 1]

	var hub := _map.get_node_or_null("Roads/Hub") as Marker3D
	if hub == null:
		_fail("Roads/Hub is missing, so there is no hub to sight down")
		return

	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = AERIAL_SIZE
	_camera.near = 0.05
	_camera.far = 400.0
	_camera.global_transform = Transform3D(
		Basis.from_euler(Vector3(-PI / 2.0, 0.0, 0.0)), Vector3(0.0, AERIAL_HEIGHT, 0.0)
	)
	var aerial := await _shoot(prefix, "aerial")
	if aerial == null:
		return
	if not _aerial_holds(aerial, hub):
		return

	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 60.0
	_camera.global_position = Vector3(0.0, 6.0, 24.0)
	_camera.look_at(Vector3(0.0, 1.0, -10.0), Vector3.UP)
	var hub_shot := await _shoot(prefix, "hub")
	if hub_shot == null:
		return

	for town_name in TOWN_NAMES:
		var marker := _town_marker(town_name)
		if marker == null:
			return
		var centre := marker.global_position
		var toward_hub := Vector3(
			hub.global_position.x - centre.x, 0.0, hub.global_position.z - centre.z
		).normalized()
		_camera.global_position = centre + toward_hub * TOWN_EYE_BACK + Vector3(0.0, TOWN_EYE_UP, 0.0)
		_camera.look_at(
			centre - toward_hub * TOWN_AIM_AHEAD + Vector3(0.0, TOWN_AIM_UP, 0.0), Vector3.UP
		)
		var town_shot := await _shoot(prefix, town_name.to_lower())
		if town_shot == null:
			return

	var started := Time.get_ticks_usec()
	for _frame in MEASURE_FRAMES:
		await get_tree().process_frame
	var elapsed := Time.get_ticks_usec() - started
	var fps := 0.0
	if elapsed > 0:
		fps = float(MEASURE_FRAMES) * 1000000.0 / float(elapsed)
	print("WORLD MAP PROBE fps %d nodes %d" % [int(round(fps)), get_tree().get_node_count()])
	print("WORLD MAP PROBE OK")
	get_tree().quit(0)


func _aerial_holds(aerial: Image, hub: Marker3D) -> bool:
	var origin_px := _camera.unproject_position(Vector3.ZERO)
	var north_px := _camera.unproject_position(Vector3(0.0, 0.0, -100.0))
	var east_px := _camera.unproject_position(Vector3(100.0, 0.0, 0.0))
	print(
		"WORLD MAP PROBE axes origin (%.1f, %.1f) north (%.1f, %.1f) east (%.1f, %.1f)"
		% [origin_px.x, origin_px.y, north_px.x, north_px.y, east_px.x, east_px.y]
	)
	if north_px.y >= origin_px.y or east_px.x <= origin_px.x:
		_fail("the aerial basis does not put world -Z at the top and world +X to the right")
		return false

	for town_name in TOWN_NAMES:
		var marker := _town_marker(town_name)
		if marker == null:
			return false
		var at := _camera.unproject_position(marker.global_position)
		var tight := _fraction(aerial, at, ROOF_BOX_TIGHT, _is_roof_red)
		var wide := _fraction(aerial, at, ROOF_BOX_WIDE, _is_roof_red)
		if tight < 0.0 or wide < 0.0:
			_fail("%s projects to (%.1f, %.1f), off the image" % [town_name, at.x, at.y])
			return false
		print(
			"WORLD MAP PROBE roof %s 40px %.2f%% 120px %.2f%%"
			% [town_name.to_lower(), tight * 100.0, wide * 100.0]
		)
		if wide < ROOF_MIN_FRACTION:
			_fail(
				"%s draws %.2f%% roof_red in its 120px box, under the %.0f%% a town of houses owes"
				% [town_name, wide * 100.0, ROOF_MIN_FRACTION * 100.0]
			)
			return false

	var spokes: Array = _map.get_node("Roads").get_meta("spokes")
	var northmere: PackedVector2Array = spokes[0]
	var approach := (northmere[northmere.size() - 2] - northmere[northmere.size() - 1]).normalized()
	var road_at := hub.global_position + Vector3(approach.x, 0.0, approach.y) * ROAD_SAMPLE_OUT
	var road_px := _camera.unproject_position(road_at)
	var dirt := _fraction(aerial, road_px, HUB_BOX, _is_dirt_brown)
	if dirt < 0.0:
		_fail("the road sample projects to (%.1f, %.1f), off the image" % [road_px.x, road_px.y])
		return false
	print("WORLD MAP PROBE road 20px dirt_brown %.2f%%" % [dirt * 100.0])
	if dirt < HUB_MIN_FRACTION:
		_fail(
			"the Northmere road %.0f u out of the hub draws %.2f%% dirt_brown, under the %.0f%% a road owes"
			% [ROAD_SAMPLE_OUT, dirt * 100.0, HUB_MIN_FRACTION * 100.0]
		)
		return false

	var sky_roof := _fraction(aerial, SKY_AT, SKY_BOX, _is_roof_red)
	var sky_dirt := _fraction(aerial, SKY_AT, SKY_BOX, _is_dirt_brown)
	if sky_roof < 0.0 or sky_dirt < 0.0:
		_fail("the sky control box at (%.0f, %.0f) covers no pixels" % [SKY_AT.x, SKY_AT.y])
		return false
	print(
		"WORLD MAP PROBE control (%.0f, %.0f) mean %s roof_red %.2f%% dirt_brown %.2f%%"
		% [SKY_AT.x, SKY_AT.y, _mean_colour(aerial, SKY_AT, SKY_BOX), sky_roof * 100.0, sky_dirt * 100.0]
	)
	if sky_roof > 0.0 or sky_dirt > 0.0:
		_fail(
			"the control box off the map matches roof_red %.2f%% and dirt_brown %.2f%%, so the classifiers do not discriminate"
			% [sky_roof * 100.0, sky_dirt * 100.0]
		)
		return false
	return true


func _town_marker(town_name: String) -> Marker3D:
	var marker := _map.get_node_or_null("Towns/%s/Center" % town_name) as Marker3D
	if marker == null:
		_fail("Towns/%s/Center is missing" % town_name)
	return marker


func _shoot(prefix: String, shot_name: String) -> Image:
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s_%s.png" % [prefix, shot_name]
	var error := image.save_png(path)
	if error != OK:
		_fail("could not save %s: %s" % [path, error_string(error)])
		return null
	print("WORLD MAP PROBE shot %s %s" % [shot_name, ProjectSettings.globalize_path(path)])
	return image


func _fraction(image: Image, at: Vector2, box: int, classify: Callable) -> float:
	var clipped := _clipped_box(image, at, box)
	var total := clipped.size.x * clipped.size.y
	if total <= 0:
		return -1.0
	var hits := 0
	for y in range(clipped.position.y, clipped.position.y + clipped.size.y):
		for x in range(clipped.position.x, clipped.position.x + clipped.size.x):
			if classify.call(image.get_pixel(x, y)):
				hits += 1
	return float(hits) / float(total)


func _mean_colour(image: Image, at: Vector2, box: int) -> Color:
	var clipped := _clipped_box(image, at, box)
	var total := clipped.size.x * clipped.size.y
	if total <= 0:
		return Color.BLACK
	var sum := Color(0.0, 0.0, 0.0, 0.0)
	for y in range(clipped.position.y, clipped.position.y + clipped.size.y):
		for x in range(clipped.position.x, clipped.position.x + clipped.size.x):
			sum += image.get_pixel(x, y)
	return sum / float(total)


static func _clipped_box(image: Image, at: Vector2, box: int) -> Rect2i:
	var half := box / 2
	var wanted := Rect2i(int(roundf(at.x)) - half, int(roundf(at.y)) - half, box, box)
	return wanted.intersection(Rect2i(Vector2i.ZERO, image.get_size()))


static func _is_roof_red(colour: Color) -> bool:
	return colour.r > 0.5 and colour.g < 0.45 and colour.b < 0.4


static func _is_dirt_brown(colour: Color) -> bool:
	return colour.r > 0.35 and colour.r > colour.b + 0.1 and colour.g < 0.5


func _fail(reason: String) -> void:
	push_error("WORLD MAP PROBE FAILED: %s" % reason)
	get_tree().quit(1)
