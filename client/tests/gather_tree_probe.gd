extends Node3D


const SETTLE_FRAMES := 30
const RESTATE_FRAMES := 8
const BACKGROUND := Color(0.0, 1.0, 0.0, 1.0)
const BACKGROUND_TOLERANCE := 0.15
const REFERENCE_HEIGHT := 1.7
const TREE_HALF_WIDTH := 2.4
const STUMP_HALF_WIDTH := 0.7
const AVATAR_HALF_WIDTH := 0.6
const REFERENCE_HALF_WIDTH := 0.3
const REFERENCE_TOLERANCE := 0.05
const MINIMUM_SILHOUETTE := 0.2
const DEFAULT_PREFIX := "user://gather_tree"

@onready var _camera: Camera3D = $Camera
@onready var _node: StaticBody3D = $ResourceNode
@onready var _avatar: Node3D = $Avatar
@onready var _reference: MeshInstance3D = $Reference


func _ready() -> void:
	_avatar.update_to_tick(0)
	_node.configure(1, "tree", "full")
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var full_image := get_viewport().get_texture().get_image()
	var prefix := _output_prefix()
	var full_path := prefix + "_full.png"
	if not _save(full_image, full_path):
		return
	var tree_height := _silhouette_height(full_image, _node.global_position, TREE_HALF_WIDTH)
	var player_height := _silhouette_height(
		full_image, _avatar.global_position, AVATAR_HALF_WIDTH
	)
	var reference_feet := _reference.global_position - Vector3(0.0, REFERENCE_HEIGHT / 2.0, 0.0)
	var reference_height := _silhouette_height(
		full_image, reference_feet, REFERENCE_HALF_WIDTH
	)
	print(
		"TREE PROBE full %.3f u, player %.3f u, reference %.3f u (authored %.3f), shot %s"
		% [
			tree_height,
			player_height,
			reference_height,
			REFERENCE_HEIGHT,
			ProjectSettings.globalize_path(full_path),
		]
	)
	if not _drawn("tree", tree_height) or not _drawn("player", player_height):
		return
	if not _control_holds(reference_height):
		return
	if not _taller(tree_height, player_height):
		return

	_node.apply_state("depleted")
	for _frame in RESTATE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var depleted_image := get_viewport().get_texture().get_image()
	var depleted_path := prefix + "_depleted.png"
	if not _save(depleted_image, depleted_path):
		return
	var stump_height := _silhouette_height(
		depleted_image, _node.global_position, STUMP_HALF_WIDTH
	)
	print(
		"TREE PROBE depleted %.3f u, shot %s"
		% [stump_height, ProjectSettings.globalize_path(depleted_path)]
	)
	if not _drawn("stump", stump_height):
		return
	if not _taller(tree_height, stump_height):
		return
	print("TREE PROBE OK")
	get_tree().quit(0)


func _drawn(subject: String, height: float) -> bool:
	if height >= MINIMUM_SILHOUETTE:
		return true
	_fail(
		"the %s read %.3f u, under the %.3f u floor, so its band drew nothing to measure"
		% [subject, height, MINIMUM_SILHOUETTE]
	)
	return false


func _control_holds(reference_height: float) -> bool:
	if absf(reference_height - REFERENCE_HEIGHT) <= REFERENCE_TOLERANCE:
		return true
	_fail(
		"the %.3f u control box read back as %.3f u, so the method is wrong, not the art"
		% [REFERENCE_HEIGHT, reference_height]
	)
	return false


func _taller(tall: float, short: float) -> bool:
	if tall > short:
		return true
	_fail("%.3f u does not stand over %.3f u" % [tall, short])
	return false


func _fail(reason: String) -> void:
	push_error("TREE PROBE FAILED: %s" % reason)
	get_tree().quit(1)


func _save(image: Image, path: String) -> bool:
	var error := image.save_png(path)
	if error == OK:
		return true
	_fail("could not save %s: %s" % [path, error_string(error)])
	return false


func _silhouette_height(image: Image, feet: Vector3, half_width: float) -> float:
	var feet_px := _camera.unproject_position(feet)
	var pixels_per_unit := feet_px.y - _camera.unproject_position(feet + Vector3.UP).y
	var left := _camera.unproject_position(feet + Vector3.LEFT * half_width).x
	var right := _camera.unproject_position(feet + Vector3.RIGHT * half_width).x
	var top := feet_px.y
	for x in range(int(minf(left, right)), int(maxf(left, right)) + 1):
		for y in range(0, int(feet_px.y) + 1):
			if _is_background(image.get_pixel(x, y)):
				continue
			top = minf(top, y)
			break
	return (feet_px.y - top) / pixels_per_unit


static func _is_background(pixel: Color) -> bool:
	return (
		absf(pixel.r - BACKGROUND.r) < BACKGROUND_TOLERANCE
		and absf(pixel.g - BACKGROUND.g) < BACKGROUND_TOLERANCE
		and absf(pixel.b - BACKGROUND.b) < BACKGROUND_TOLERANCE
	)


static func _output_prefix() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--out")
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return DEFAULT_PREFIX
