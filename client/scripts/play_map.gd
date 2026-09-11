extends RefCounted


const ENV_NAME := "MARQUE_MAP"
const FLAG := "--map"

const WORLD_PATH := "res://scenes/world_map.tscn"
const ARENA_PATH := "res://scenes/arena_ring_of_trials.tscn"

const WORLD_KEYS := ["", "world", "world_map"]
const ARENA_KEYS := ["arena", "arena_ring_of_trials", "ring_of_trials"]


static func resolve_path(args: PackedStringArray = PackedStringArray()) -> String:
	var key := _requested_key(args)
	if key in ARENA_KEYS:
		return ARENA_PATH
	if key in WORLD_KEYS:
		return WORLD_PATH
	push_warning("play_map: unknown %s=%s, using world_map" % [ENV_NAME, key])
	return WORLD_PATH


static func apply_to(host: Node, args: PackedStringArray = PackedStringArray()) -> String:
	var path := resolve_path(args)
	if path == WORLD_PATH:
		return path
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("play_map: failed to load %s" % path)
		return WORLD_PATH
	var old := host.get_node_or_null("WorldMap")
	if old != null:
		host.remove_child(old)
		old.free()
	var map := packed.instantiate() as Node
	if map == null:
		push_error("play_map: %s root is not a Node" % path)
		return WORLD_PATH
	map.name = "WorldMap"
	host.add_child(map)
	host.move_child(map, 0)
	return path


static func _requested_key(args: PackedStringArray) -> String:
	var from_args := _argument_after(args, FLAG).strip_edges().to_lower()
	if not from_args.is_empty():
		return from_args
	return OS.get_environment(ENV_NAME).strip_edges().to_lower()


static func _argument_after(args: PackedStringArray, flag: String) -> String:
	var index := args.find(flag)
	if index < 0 or index + 1 >= args.size():
		return ""
	return str(args[index + 1])
