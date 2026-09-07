extends Node3D


const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")

const SHOT_PATH := "user://walk_demo.png"

const TICK_MS := 150
const START_TICK := 1000
const SAMPLE_TICK := START_TICK + 10
const SPEED := 3.0
const PATH_START := Vector2(-5.0, 3.0)
const PATH_END := Vector2(5.0, 3.0)
const EXPECTED_AT_SAMPLE := Vector2(-0.5, 3.0)

const WARMUP_FRAMES := 30

const SHADOW_SAMPLE_DISTANCES: Array = [0.55, 0.75, 0.95, 1.15, 1.35]
const SHADOW_DARKENING := 0.2
const AVATAR_SEARCH_RADIUS := 70
const SAMPLE_HEIGHT := 1.2

static func is_armour_pixel(colour: Color) -> bool:
	if colour.b - colour.r > 0.10 and colour.b > colour.g:
		return true
	return colour.b > 0.25 and colour.r < 0.5 and colour.b - colour.g > 0.05

var _failures: Array[String] = []


func _ready() -> void:
	var world: Node3D = $World
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	avatar.configure(1, TICK_MS)
	world.get_node("RemotePlayers").add_child(avatar)
	avatar.teleport_to(PATH_START.x, PATH_START.y)
	avatar.follow_path(PackedVector2Array([PATH_START, PATH_END]), START_TICK, SPEED)
	avatar.update_to_tick(SAMPLE_TICK)

	for _frame in WARMUP_FRAMES:
		avatar.update_to_tick(SAMPLE_TICK)
		await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(SHOT_PATH)
	if error != OK:
		_fail("could not save %s: %d" % [SHOT_PATH, error])
	else:
		print("screenshot: ", ProjectSettings.globalize_path(SHOT_PATH))

	var camera: Camera3D = world.get_node("CameraRig/Camera3D")
	_check_the_avatar_left_its_origin(avatar)
	_check_the_avatar_is_on_screen_where_the_walker_says(image, camera, avatar)
	_check_the_avatar_casts_a_shadow(image, camera, avatar)

	if _failures.is_empty():
		print("PASS: the avatar walked and it casts a shadow")
		get_tree().quit(0)
		return
	printerr("FAIL: %d visual check(s) failed" % _failures.size())
	for failure in _failures:
		printerr("  - " + failure)
	get_tree().quit(1)


func _check_the_avatar_left_its_origin(avatar: PlayerAvatar) -> void:
	var here := Vector2(avatar.position.x, avatar.position.z)
	_check(
		here.distance_to(EXPECTED_AT_SAMPLE) < 0.001,
		"the avatar is where the walker says at tick %d: expected %v, got %v"
		% [SAMPLE_TICK, EXPECTED_AT_SAMPLE, here],
	)
	_check(
		here.distance_to(PATH_START) > 1.0,
		"it left points[0] (moved %.2f units)" % here.distance_to(PATH_START),
	)
	_check(
		here.distance_to(PATH_END) > 1.0,
		"it has not reached the final point either (%.2f units short)"
		% here.distance_to(PATH_END),
	)


func _check_the_avatar_is_on_screen_where_the_walker_says(
	image: Image, camera: Camera3D, avatar: PlayerAvatar
) -> void:
	var head := avatar.global_position + Vector3(0.0, SAMPLE_HEIGHT, 0.0)
	_check(not camera.is_position_behind(head), "the avatar is in front of the camera")
	var centre := camera.unproject_position(head)

	var blue_pixels := 0
	for dy in range(-AVATAR_SEARCH_RADIUS, AVATAR_SEARCH_RADIUS + 1, 3):
		for dx in range(-AVATAR_SEARCH_RADIUS, AVATAR_SEARCH_RADIUS + 1, 3):
			var colour := _pixel(image, centre + Vector2(dx, dy))
			if is_armour_pixel(colour):
				blue_pixels += 1
	_check(
		blue_pixels > 20,
		(
			"the avatar's armour is on screen at its projected position (%d armour samples near %v)"
			% [blue_pixels, centre]
		),
	)


func _check_the_avatar_casts_a_shadow(
	image: Image, camera: Camera3D, avatar: PlayerAvatar
) -> void:
	var sun: DirectionalLight3D = $World/Sun
	var travel := -sun.global_transform.basis.z
	var shadow_axis := Vector2(travel.x, travel.z).normalized()
	_check(
		travel.y < -0.1,
		"the sun points down at the world, not at the sky (light y = %.3f)" % travel.y,
	)

	var feet := avatar.global_position
	var shadowed := _mean_luminance(image, camera, feet, shadow_axis)
	var lit := _mean_luminance(image, camera, feet, -shadow_axis)
	_check(lit > 0.0, "the lit ground samples are not black (%.4f)" % lit)
	if lit <= 0.0:
		return
	var darkening := 1.0 - shadowed / lit
	_check(
		darkening > SHADOW_DARKENING,
		(
			"the ground in the sun's shadow direction is at least %.0f%% darker than the lit side (shadowed %.4f, lit %.4f, %.1f%% darker)"
			% [SHADOW_DARKENING * 100.0, shadowed, lit, darkening * 100.0]
		),
	)


func _mean_luminance(
	image: Image, camera: Camera3D, feet: Vector3, axis: Vector2
) -> float:
	var total := 0.0
	for distance in SHADOW_SAMPLE_DISTANCES:
		var ground := feet + Vector3(axis.x, 0.0, axis.y) * float(distance)
		total += _luminance(_pixel(image, camera.unproject_position(ground)))
	return total / float(SHADOW_SAMPLE_DISTANCES.size())


func _pixel(image: Image, at: Vector2) -> Color:
	var x := clampi(int(at.x), 0, image.get_width() - 1)
	var y := clampi(int(at.y), 0, image.get_height() - 1)
	return image.get_pixel(x, y)


func _luminance(colour: Color) -> float:
	return 0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok    " + message)
		return
	_failures.append(message)
	print("  FAIL  " + message)


func _fail(message: String) -> void:
	_failures.append(message)
	printerr(message)
