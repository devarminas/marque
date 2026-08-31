extends Node3D

## Windowed visual check for the avatar and the walker. Not part of the game.
##
## Anything genuinely visual cannot be checked headless (NOTES.md, "Headless
## testing"), so this scene renders itself, captures its own frame, and asserts
## on the pixels. The desktop is not automated.
##
## [codeblock]
## godot --path client res://scenes/walk_demo.tscn
## [/codeblock]
##
## It instances [code]main.tscn[/code] for the ground, the sun, and the camera
## rig rather than duplicating them, spawns avatars into that scene's authored
## [code]RemotePlayers[/code] container, and drives them to a fixed tick. The
## tick is fed, not read from a clock, so the captured frame is the same every
## run.
##
## Two things are asserted, both of which a plausible-looking build can fail:
##
## 1. [b]The avatar moved.[/b] Its logical position is mid-path, and blue pixels
##    are actually there on screen. "The image is not black" is far too weak.
## 2. [b]The avatar casts a shadow.[/b] Ground samples along the sun's shadow
##    axis are compared against the mirrored samples on the lit side. An M0c
##    build whose sun pointed at the sky passed a weaker check than this
##    (NOTES.md, "Godot authoring traps").

const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")

const SHOT_PATH := "user://walk_demo.png"

const TICK_MS := 150
const START_TICK := 1000
## 10 ticks is 1.5s, which at 3 u/s is 4.5 units along a 10 unit path: mid-walk
## by a margin no rounding can close.
const SAMPLE_TICK := START_TICK + 10
const SPEED := 3.0
const PATH_START := Vector2(-5.0, 3.0)
const PATH_END := Vector2(5.0, 3.0)
const EXPECTED_AT_SAMPLE := Vector2(-0.5, 3.0)

## Frames to let the renderer settle. The first frame has no shadow map and no
## resolved sky, so a capture there proves nothing.
const WARMUP_FRAMES := 30

## Ground offsets, in world units from the avatar's feet, sampled along the
## shadow axis. They span more than one 1m checker square in both directions so
## the checker's two shades average out of the comparison.
const SHADOW_SAMPLE_DISTANCES: Array = [0.55, 0.75, 0.95, 1.15, 1.35]
## How much darker the shadowed side must be than the lit side, as a fraction of
## the lit luminance. A real cast shadow is far past this; ambient-only lighting
## with no shadow is far under it.
const SHADOW_DARKENING := 0.2
## Radius in pixels to hunt for the avatar's blue around its projected centre.
const AVATAR_SEARCH_RADIUS := 60
## How much more blue than red a pixel needs to count as the avatar's material.
const AVATAR_BLUE_MARGIN := 0.15

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
		# The avatar has no clock, so re-feeding the same tick every frame holds
		# it still while the renderer settles. Same tick, same position.
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


## Mid-path, not at either end. An avatar that never got its path sits at
## points[0], and one whose clamp is broken sits at the far end.
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


## The logical position above proves the arithmetic. This proves the body was
## actually drawn there, which is the half a headless test cannot reach.
func _check_the_avatar_is_on_screen_where_the_walker_says(
	image: Image, camera: Camera3D, avatar: PlayerAvatar
) -> void:
	var head := avatar.global_position + Vector3(0.0, 0.9, 0.0)
	_check(not camera.is_position_behind(head), "the avatar is in front of the camera")
	var centre := camera.unproject_position(head)

	var blue_pixels := 0
	for dy in range(-AVATAR_SEARCH_RADIUS, AVATAR_SEARCH_RADIUS + 1, 3):
		for dx in range(-AVATAR_SEARCH_RADIUS, AVATAR_SEARCH_RADIUS + 1, 3):
			var colour := _pixel(image, centre + Vector2(dx, dy))
			if colour.b - colour.r > AVATAR_BLUE_MARGIN and colour.b > colour.g:
				blue_pixels += 1
	_check(
		blue_pixels > 20,
		(
			"the avatar's blue is on screen at its projected position (%d blue samples near %v)"
			% [blue_pixels, centre]
		),
	)


## The sun's shadow falls in the direction the light travels, projected onto the
## ground. Ground a metre along that axis from the avatar's feet must be
## meaningfully darker than the same ground a metre the other way.
##
## This is what catches a sun pointing at the sky: without a cast shadow both
## sides are lit identically and the ratio collapses to 1.
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
