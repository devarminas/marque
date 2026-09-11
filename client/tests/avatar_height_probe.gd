extends Node3D


const SETTLE_FRAMES := 30
const BACKGROUND := Color(0.0, 1.0, 0.0, 1.0)
const BACKGROUND_TOLERANCE := 0.15
const REFERENCE_HEIGHT := 1.7
const DEFAULT_OUTPUT := "user://avatar_height.png"

@onready var _camera: Camera3D = $Camera
@onready var _avatar: Node3D = $Avatar
@onready var _reference: MeshInstance3D = $Reference


func _ready() -> void:
	_avatar.present_at(0.0, 0.0, false)
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var output := _output_path()
	var error := image.save_png(output)
	if error != OK:
		push_error("HEIGHT PROBE could not save %s: %s" % [output, error_string(error)])
		get_tree().quit(1)
		return
	var avatar_height := _silhouette_height(image, _avatar.global_position, 0.6)
	var reference_feet := _reference.global_position - Vector3(0.0, REFERENCE_HEIGHT / 2.0, 0.0)
	var reference_height := _silhouette_height(image, reference_feet, 0.3)
	print(
		"HEIGHT PROBE avatar %.3f u, reference %.3f u (authored %.3f), shot %s"
		% [avatar_height, reference_height, REFERENCE_HEIGHT, ProjectSettings.globalize_path(output)]
	)
	get_tree().quit(0)


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


static func _output_path() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--out")
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return DEFAULT_OUTPUT
