extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var value: Object = ClassDB.instantiate(args[0])
	print("ARM360_EXTENSION_PROPERTY_LOADED ", args[0], ".", args[1])
	value[args[1]] = value[args[1]]
	print("ARM360_PROPERTY_ASSIGNMENT_UNEXPECTEDLY_SUCCEEDED")
	quit(1)
