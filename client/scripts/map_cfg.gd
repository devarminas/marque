extends RefCounted


const MAP_VILLAGE := "village"
const MAP_ARENA_RING_OF_TRIALS := "arena_ring_of_trials"

const WORLD_HALF_EXTENT := 128.0
const ARENA_HALF_EXTENT := 84.0
const ARENA_FLOOR_Y := 0.4

const PlayMap := preload("res://scripts/play_map.gd")
const NavMesh := preload("res://scripts/nav_mesh.gd")


static func id_for_play_path(path: String) -> String:
	if path == PlayMap.ARENA_PATH:
		return MAP_ARENA_RING_OF_TRIALS
	return MAP_VILLAGE


static func id_from_args(args: PackedStringArray = PackedStringArray()) -> String:
	return id_for_play_path(PlayMap.resolve_path(args))


static func half_extent(map_id: String) -> float:
	if map_id == MAP_ARENA_RING_OF_TRIALS:
		return ARENA_HALF_EXTENT
	return WORLD_HALF_EXTENT


static func ground_y(map_id: String) -> float:
	if map_id == MAP_ARENA_RING_OF_TRIALS:
		return ARENA_FLOOR_Y
	return 0.0


static func load_nav(map_id: String):
	if map_id != MAP_ARENA_RING_OF_TRIALS:
		return null
	return NavMesh.load_arena()
