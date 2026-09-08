extends Node3D


const ClassDefs := preload("res://scripts/class_defs.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")

const SETTLE_FRAMES := 30
const CLOSEUP_FRAMES := 4
const CLOSEUP_DISTANCE := 2.6
const CLOSEUP_HEIGHT := 1.2
const WALK_SECONDS := 0.5
const WORN_SLOTS := ["helmet", "left hand", "chest", "right hand", "feet", "trousers"]

@onready var _stand: Node3D = $Stand
@onready var _camera: Camera3D = $GameCamera


func _ready() -> void:
	var staged := PackedStringArray()
	for post in _stand.get_children():
		var kind := String(post.get_meta("kind", ""))
		var hands := String(post.get_meta("hands", "")).split(",", false)
		if kind.is_empty() or hands.is_empty():
			push_error("HAND TOOL PROBE: post %s names no kind and hands to stage" % post.name)
			get_tree().quit(1)
			return
		var kinds := PackedStringArray()
		for _hand in hands:
			kinds.append(kind)
		var avatar := post.get_node("Avatar") as PlayerAvatar
		if avatar == null:
			push_error("HAND TOOL PROBE: post %s stands no PlayerAvatar" % post.name)
			get_tree().quit(1)
			return
		var class_id := String(post.get_meta("class_id", ""))
		if class_id.is_empty():
			push_error("HAND TOOL PROBE: post %s names no class_id to dress" % post.name)
			get_tree().quit(1)
			return
		avatar.apply_class(class_id)
		if avatar.worn_outfit().is_empty():
			push_error(
				'HAND TOOL PROBE: post %s named class_id "%s", which dressed no outfit, so the'
				% [post.name, class_id]
				+ " shot cannot show the tool in a sleeve's fist"
			)
			get_tree().quit(1)
			return
		avatar.apply_equipment(PackedStringArray(WORN_SLOTS), hands, kinds)
		if (
			avatar.gripped(GripDefs.GRIP_HAND).is_empty()
			and avatar.gripped(GripDefs.OFF_HAND).is_empty()
		):
			push_error("HAND TOOL PROBE: post %s ended up empty-handed with %s" % [post.name, kind])
			get_tree().quit(1)
			return
		staged.append(kind)

	for kind: String in _server_tool_kinds():
		if not staged.has(kind):
			push_error(
				"HAND TOOL PROBE: no post holds %s, so this shot proves less than it claims" % kind
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

	var shot := "%s/hand_tools.png" % _out_dir()
	var error := get_viewport().get_texture().get_image().save_png(shot)
	if error != OK:
		push_error("HAND TOOL PROBE could not save %s: %s" % [shot, error_string(error)])
		get_tree().quit(1)
		return
	print("HAND TOOL PROBE shot %s" % ProjectSettings.globalize_path(shot))

	await _closeups()
	print("HAND TOOL PROBE OK")
	get_tree().quit(0)


func _closeups() -> void:
	var orbit := _camera.transform
	for post in _stand.get_children():
		_camera.position = (
			post.position
			+ Vector3(0.0, CLOSEUP_HEIGHT, 0.0)
			+ orbit.basis.z * CLOSEUP_DISTANCE
		)
		for _frame in CLOSEUP_FRAMES:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var kind := String(post.get_meta("kind", ""))
		var shot := "%s/tool_%s.png" % [_out_dir(), kind]
		var error := get_viewport().get_texture().get_image().save_png(shot)
		if error != OK:
			push_error("HAND TOOL PROBE could not save %s: %s" % [shot, error_string(error)])
			get_tree().quit(1)
			return
		print("HAND TOOL PROBE closeup %s" % ProjectSettings.globalize_path(shot))
	_camera.transform = orbit


static func _server_tool_kinds() -> PackedStringArray:
	var catalog := ClassDefs.load_sets()
	var kinds := PackedStringArray()
	for set_id: String in ClassDefs.set_ids(catalog):
		var entry: Variant = ClassDefs.get_set(catalog, set_id)
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var tools: Variant = (entry as Dictionary).get("tools")
		if typeof(tools) != TYPE_DICTIONARY:
			continue
		for kind: String in (tools as Dictionary).keys():
			if not kinds.has(kind):
				kinds.append(kind)
	return kinds


static func _out_dir() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--out")
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return "user://"
