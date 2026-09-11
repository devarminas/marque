extends Node3D


const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")

const SHOT_PATH := "user://walk_demo.png"

const SAMPLE_AT := Vector2(-0.5, 3.0)

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
	# Pose-driven placement (ARM-239). Player polyline walk is retired.
	var world: Node3D = $World
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	avatar.configure(1)
	world.get_node("RemotePlayers").add_child(avatar)
	avatar.present_at(SAMPLE_AT.x, SAMPLE_AT.y, true)

	for _frame in WARMUP_FRAMES:
		avatar.present_at(SAMPLE_AT.x, SAMPLE_AT.y, true)
		await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(SHOT_PATH)
	if error != OK:
		_fail("could not save %s: %d" % [SHOT_PATH, error])
	else:
		print("screenshot: ", ProjectSettings.globalize_path(SHOT_PATH))

	var camera: Camera3D = world.get_node("CameraRig/Camera3D")
	_check_the_avatar_is_where_present_at_put_it(avatar)
	_check_the_avatar_is_on_screen(image, camera, avatar)
	_check_the_avatar_casts_a_shadow(image, camera, avatar)

	if _failures.is_empty():
		print("PASS: the avatar is posed and it casts a shadow")
		get_tree().quit(0)
		return
	printerr("FAIL: %d visual check(s) failed" % _failures.size())
	for failure in _failures:
		printerr("  - " + failure)
	get_tree().quit(1)


func _check_the_avatar_is_where_present_at_put_it(avatar: PlayerAvatar) -> void:
	var here := Vector2(avatar.position.x, avatar.position.z)
	_check(
		here.distance_to(SAMPLE_AT) < 0.001,
		"the avatar stands where present_at placed it: expected %v, got %v" % [SAMPLE_AT, here],
	)


func _check_the_avatar_is_on_screen(
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
	var sun := _find_sun($World)
	if sun == null:
		_fail("no DirectionalLight3D under World to cast a shadow")
		return
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


func _find_sun(root: Node) -> DirectionalLight3D:
	if root is DirectionalLight3D:
		return root as DirectionalLight3D
	for child in root.get_children():
		var found := _find_sun(child)
		if found != null:
			return found
	return null


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
