extends SceneTree

func _initialize() -> void:
	for name in ClassDB.get_class_list():
		if not String(name).begins_with("Marque"):
			continue
		for property in ClassDB.class_get_property_list(name, true):
			print("ARM360_PROPERTY ", name, " ", property.name)
	quit(0)
