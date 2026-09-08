extends MeshInstance3D


static func color_for_ui(name: String) -> Color:
	match name:
		"green":
			return Color(0.35, 1.0, 0.45, 0.9)
		"red":
			return Color(1.0, 0.35, 0.2, 0.9)
		_:
			return Color(1.0, 1.0, 0.65, 0.9)


static func play(host: Node3D, color: Color) -> MeshInstance3D:
	if host == null or not is_instance_valid(host):
		return null
	var packed := load("res://scenes/cast_hit_fx.tscn") as PackedScene
	if packed == null:
		return null
	var flash := packed.instantiate() as MeshInstance3D
	if flash == null:
		return null
	flash.apply_color(color)
	host.add_child(flash)
	flash.start_pulse()
	return flash


func apply_color(color: Color) -> void:
	var base: Material = material_override
	if base == null:
		return
	var mat := base.duplicate() as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = color
	material_override = mat


func start_pulse() -> void:
	var mat := material_override as StandardMaterial3D
	if mat == null:
		queue_free()
		return
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "scale", Vector3(1.7, 1.7, 1.7), 0.28)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.32)
	tween.chain().tween_callback(queue_free)
