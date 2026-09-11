extends SceneTree

const SCENE := "res://scenes/arena_ring_of_trials.tscn"
const SHOT := "res://.gotmp/arena_ring_of_trials_look.png"
const FRAMES := 8


func _initialize() -> void:
	var packed: PackedScene = load(SCENE)
	var root: Node = packed.instantiate()
	get_root().add_child(root)
	var cam := root.get_node_or_null("PreviewCamera") as Camera3D
	if cam:
		cam.current = true
	call_deferred("_shoot")


func _shoot() -> void:
	for _i in FRAMES:
		await process_frame
	var image := get_root().get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.gotmp"))
	var err := image.save_png(SHOT)
	if err != OK:
		push_error("arena look shot failed: %s" % err)
		quit(1)
		return
	print("ARENA LOOK screenshot: ", ProjectSettings.globalize_path(SHOT))
	quit(0)
