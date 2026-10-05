extends SceneTree

func _initialize() -> void:
	call_deferred("exercise")

func exercise() -> void:
	var runtime: Node = load("res://tests/core_runtime.tscn").instantiate()
	root.add_child(runtime)
	var core: RefCounted = runtime.core
	var token_path := OS.get_environment("MARQUE_RUNTIME_TOKEN")
	if not runtime.connect_token(FileAccess.get_file_as_bytes(token_path)):
		quit(1)
		return
	var deadline := Time.get_ticks_msec() + 5000
	while core.tick.tick < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	if core.tick.tick != 2:
		quit(2)
		return
	if OS.get_environment("MARQUE_RUNTIME_NEGATIVE") == "recovery":
		deadline = Time.get_ticks_msec() + 15000
		while core.predicted_local_pose.mode != 1 and Time.get_ticks_msec() < deadline:
			await process_frame
		if core.predicted_local_pose.mode != 1 or core.predicted_local_pose.x != 0:
			quit(7)
			return
		FileAccess.open(token_path + ".recovery", FileAccess.WRITE).store_string("recovery")
		while core.tick.tick < 300 and Time.get_ticks_msec() < deadline:
			await process_frame
		if core.tick.tick != 300 or core.predicted_local_pose.mode != 0 or core.predicted_local_pose.x != 1:
			quit(8)
			return
		print("ARM360_LIVE_PASSIVE_BOUNDED_RECOVERY_PASS")
	elif OS.get_environment("MARQUE_RUNTIME_NEGATIVE") == "unknown":
		if core.prediction_available or core.predicted_local_pose != null or core.move(1,0,false):
			quit(3)
			return
		print("ARM360_UNKNOWN_MAP_NOT_READY_PASS")
	else:
		if not core.prediction_available or abs(core.predicted_local_pose.y - 5.8) > 0.00001:
			push_error("authored elevated arena triangle is required")
			quit(4)
			return
		var pinned: RefCounted = core.predicted_local_pose
		if not core.move(0.5,0,false):
			quit(5)
			return
		await create_timer(0.12, true).timeout
		if core.predicted_local_pose.x <= pinned.x or abs(core.predicted_local_pose.y-5.8) > 0.00001 or abs(pinned.y-5.8) > 0.00001:
			quit(6)
			return
		print("ARM360_AUTHORED_ARENA_MESH_PREDICTION_PASS")
	runtime.free()
	quit(0)
