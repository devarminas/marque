extends Node3D


const OutfitDefs := preload("res://scripts/outfit_defs.gd")

const SETTLE_FRAMES := 30
const CROP_HALF_WIDTH := 26
const CROP_TOP := 1.95
const CROP_BOTTOM := -0.06
const MIN_SEPARATION := 0.12
const WALK_SECONDS := 0.5

@onready var _stand: Node3D = $Stand
@onready var _camera: Camera3D = $GameCamera


func _ready() -> void:
	var order := PackedStringArray()
	for post in _stand.get_children():
		var class_id := String(post.get_meta("class_id", ""))
		post.get_node("Avatar").apply_class(class_id)
		order.append(class_id if not class_id.is_empty() else "(bare)")
	for class_id: String in OutfitDefs.BY_CLASS:
		if not order.has(class_id):
			push_error(
				"OUTFIT PROBE: no post stands %s, so this shot proves less than it claims"
				% class_id
			)
			get_tree().quit(1)
			return
	for post in _stand.get_children():
		var player: AnimationPlayer = post.get_node("Avatar/AnimationPlayer")
		player.play("ual2/Walk_Carry")
		player.seek(WALK_SECONDS, true)
		player.pause()
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var shot := "%s/five_classes.png" % _out_dir()
	var error := image.save_png(shot)
	if error != OK:
		push_error("OUTFIT PROBE could not save %s: %s" % [shot, error_string(error)])
		get_tree().quit(1)
		return
	print("OUTFIT PROBE shot %s" % ProjectSettings.globalize_path(shot))

	var crops: Array[Image] = []
	for post in _stand.get_children():
		crops.append(_crop(image, post))
	var pixels := crops[0].get_width() * crops[0].get_height()
	print("OUTFIT PROBE comparing %d crops of %d px each" % [crops.size(), pixels])
	if pixels <= 0:
		push_error("OUTFIT PROBE: the crop is empty, so every comparison would pass vacuously")
		get_tree().quit(1)
		return

	var worst := 9.0
	var worst_pair := ""
	for a in order.size():
		for b in range(a + 1, order.size()):
			var apart := _difference(crops[a], crops[b])
			print("OUTFIT PROBE %s vs %s: %.3f" % [order[a], order[b], apart])
			if apart < worst:
				worst = apart
				worst_pair = "%s vs %s" % [order[a], order[b]]
	print(
		"OUTFIT PROBE closest pair %s at %.3f, floor %.3f"
		% [worst_pair, worst, MIN_SEPARATION]
	)
	if worst < MIN_SEPARATION:
		push_error(
			"OUTFIT PROBE FAILED: %s look alike (%.3f < %.3f)"
			% [worst_pair, worst, MIN_SEPARATION]
		)
		get_tree().quit(1)
		return

	await _closeups()
	print("OUTFIT PROBE OK")
	get_tree().quit(0)


func _closeups() -> void:
	var orbit := _camera.transform
	for post in _stand.get_children():
		_camera.position = post.position + Vector3(0.0, 1.0, 0.0) + orbit.basis.z * 3.2
		for _frame in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var class_id := String(post.get_meta("class_id", ""))
		if class_id.is_empty():
			class_id = "bare"
		get_viewport().get_texture().get_image().save_png(
			"%s/class_%s.png" % [_out_dir(), class_id]
		)
	_camera.transform = orbit


func _crop(image: Image, post: Node3D) -> Image:
	var top := _camera.unproject_position(post.position + Vector3(0.0, CROP_TOP, 0.0))
	var bottom := _camera.unproject_position(post.position + Vector3(0.0, CROP_BOTTOM, 0.0))
	var rect := Rect2i(
		int(top.x) - CROP_HALF_WIDTH,
		int(top.y),
		CROP_HALF_WIDTH * 2,
		int(bottom.y) - int(top.y),
	)
	return image.get_region(rect)


static func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	var seen := 0
	for y in mini(a.get_height(), b.get_height()):
		for x in mini(a.get_width(), b.get_width()):
			var first := a.get_pixel(x, y)
			var second := b.get_pixel(x, y)
			total += Vector3(
				first.r - second.r, first.g - second.g, first.b - second.b
			).length()
			seen += 1
	return 0.0 if seen == 0 else total / seen


static func _out_dir() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--out")
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return "user://"
