extends RefCounted


const PlayMap := preload("res://scripts/play_map.gd")
const Assertions := preload("res://tests/assertions.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")


func run(assertions: Assertions) -> void:
	_test_default_is_world(assertions)
	_test_env_selects_arena(assertions)
	_test_flag_overrides_env(assertions)
	_test_apply_swaps_worldmap_node(assertions)
	_test_avatar_stands_on_arena_floor(assertions)
	assertions.finish()


func _test_default_is_world(assertions: Assertions) -> void:
	OS.set_environment(PlayMap.ENV_NAME, "")
	assertions.check(
		PlayMap.resolve_path() == PlayMap.WORLD_PATH,
		"empty MARQUE_MAP resolves to world_map",
	)
	OS.set_environment(PlayMap.ENV_NAME, "world")
	assertions.check(
		PlayMap.resolve_path() == PlayMap.WORLD_PATH,
		"MARQUE_MAP=world resolves to world_map",
	)


func _test_env_selects_arena(assertions: Assertions) -> void:
	OS.set_environment(PlayMap.ENV_NAME, "arena")
	assertions.check(
		PlayMap.resolve_path() == PlayMap.ARENA_PATH,
		"MARQUE_MAP=arena resolves to Ring of Trials",
	)
	OS.set_environment(PlayMap.ENV_NAME, "")


func _test_flag_overrides_env(assertions: Assertions) -> void:
	OS.set_environment(PlayMap.ENV_NAME, "world")
	var args := PackedStringArray([PlayMap.FLAG, "arena"])
	assertions.check(
		PlayMap.resolve_path(args) == PlayMap.ARENA_PATH,
		"--map arena overrides MARQUE_MAP=world",
	)
	OS.set_environment(PlayMap.ENV_NAME, "")


func _test_apply_swaps_worldmap_node(assertions: Assertions) -> void:
	OS.set_environment(PlayMap.ENV_NAME, "arena")
	var host := Node3D.new()
	var stub := Node3D.new()
	stub.name = "WorldMap"
	host.add_child(stub)
	var path := PlayMap.apply_to(host)
	assertions.check(path == PlayMap.ARENA_PATH, "apply reports arena path")
	var map := host.get_node_or_null("WorldMap") as Node3D
	assertions.check(map != null, "host still has a WorldMap child")
	assertions.check(map != stub, "stub WorldMap was replaced")
	assertions.check(
		map != null and map.get_node_or_null("Geometry") != null,
		"arena WorldMap authors Geometry",
	)
	assertions.check(
		map != null and map.get_node_or_null("NavigationRegion3D") != null,
		"arena WorldMap keeps NavigationRegion3D",
	)
	host.free()
	OS.set_environment(PlayMap.ENV_NAME, "")


func _test_avatar_stands_on_arena_floor(assertions: Assertions) -> void:
	OS.set_environment(PlayMap.ENV_NAME, "arena")
	var host := Node3D.new()
	var stub := Node3D.new()
	stub.name = "WorldMap"
	host.add_child(stub)
	PlayMap.apply_to(host)
	var map := host.get_node_or_null("WorldMap") as Node3D
	assertions.check(
		map != null and map.scene_file_path == PlayMap.ARENA_PATH,
		"play host WorldMap is the Ring of Trials scene",
	)
	var avatar := PlayerAvatarScript.new()
	host.add_child(avatar)
	avatar.ground_y = 0.0
	avatar.present_at(0.0, 0.0, false, 0.0)
	assertions.check(
		avatar.get_parent() == host and map != null and map.get_parent() == host,
		"avatar and arena share the play host",
	)
	assertions.check(
		avatar.position.is_equal_approx(Vector3(0.0, 0.0, 0.0)),
		"local avatar stands at arena floor origin under wish→pose Y=0",
	)
	host.free()
	OS.set_environment(PlayMap.ENV_NAME, "")
