extends RefCounted


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
	var flash := MeshInstance3D.new()
	flash.name = "CastHitFx"
	var sphere := SphereMesh.new()
	sphere.radius = 0.55
	sphere.height = 1.1
	flash.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	flash.material_override = mat
	flash.position = Vector3(0.0, 1.0, 0.0)
	host.add_child(flash)
	var tween := host.create_tween()
	tween.set_parallel(true)
	tween.tween_property(flash, "scale", Vector3(1.7, 1.7, 1.7), 0.28)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.32)
	tween.chain().tween_callback(flash.queue_free)
	return flash
