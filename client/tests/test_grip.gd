extends Node3D


const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")
const CharacterVisual := preload("res://scripts/character_visual.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const Assertions := preload("res://tests/assertions.gd")

const TICK_MS := 100
const SOCKET_COUNT := 2
const TWO_HANDED_KINDS := ["staff", "bow", "lumberjack_axe"]
const REACH_FLOOR := 0.2
const PLAYER_HEIGHT := 1.7
const MIN_TOOL_EXTENT := 0.25
const MAX_TOOL_EXTENT := 2.2
const MAX_SOCKET_ESCAPE := 0.1
const DETACH_BONE_SHIFT := Vector3(0.0, 0.5, 0.0)
const DETACH_DRIFT_EPSILON := 1.0e-4

const WELCOME_FRAME := (
	'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
	+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100}]}}'
)

@onready var _avatars: Node3D = $Avatars
@onready var _world: Node3D = $World

var _assertions: Assertions = null
var _finished := false
var _hands := GripDefs.hands()
var _worn_slots := PackedStringArray(["helmet", "left hand", "chest", "right hand", "feet", "trousers"])


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures if _assertions != null else PackedStringArray()


func get_assertion_count() -> int:
	return _assertions.assertion_count if _assertions != null else 0


func _ready() -> void:
	_assertions = Assertions.new()

	_test_the_sockets_hold_the_generated_item_for_every_tool_the_server_ships()
	_test_the_rig_carries_both_hand_bones()
	_test_a_bare_avatar_grips_nothing_until_a_sword_arrives()
	_test_an_empty_restatement_clears_both_hands()
	_test_a_two_handed_kind_shows_exactly_one_mesh()
	_test_a_knight_kit_shows_its_pieces_and_hides_the_regions_they_cover()
	_test_every_tool_reads_against_a_player_sized_avatar()
	await _test_a_detached_body_leaves_the_socket_where_it_was()
	await _test_an_equipment_frame_arms_the_local_avatar()

	_finished = true


func _test_the_sockets_hold_the_generated_item_for_every_tool_the_server_ships() -> void:
	var avatar := _spawn(1)
	var kinds := ClassDefs.tool_kinds(ClassDefs.load_sets())
	var items: Dictionary = CharacterVisual.contract().hand_items
	_assertions.check(kinds.size() > 0, "shared/sets.json resolved %d tool kind(s)" % kinds.size())
	var grip := avatar.get_node_or_null("Grip") as Node3D
	_assertions.check(
		grip != null and grip.get_child_count() == SOCKET_COUNT,
		"Grip authors exactly the two hand sockets, got %d" % (0 if grip == null else grip.get_child_count()),
	)
	if grip == null:
		avatar.queue_free()
		return
	for hand: String in _hands:
		var socket := grip.get_node_or_null(NodePath(hand)) as Node3D
		_assertions.check(socket != null, 'Grip authors a "%s" socket' % hand)
		if socket == null:
			continue
		var authored := PackedStringArray()
		for child in socket.get_children():
			authored.append(String(child.name))
			_assertions.check(
				child.scene_file_path == items.get(String(child.name), ""),
				"%s/%s instances the generated %s, got %s" % [hand, child.name, items.get(String(child.name), "?"), child.scene_file_path],
			)
		authored.sort()
		_assertions.check(
			authored == kinds,
			"the %s socket authors exactly the server's tool kinds [%s], got [%s]" % [hand, ", ".join(kinds), ", ".join(authored)],
		)
	avatar.queue_free()


func _test_the_rig_carries_both_hand_bones() -> void:
	var avatar := _spawn(3)
	var skeleton := avatar.get_node_or_null("Body/Rig/Skeleton3D") as Skeleton3D
	_assertions.check(skeleton != null, "the body carries the contract rig")
	if skeleton == null:
		avatar.queue_free()
		return
	for bone_name: String in ["hand_l", "hand_r"]:
		_assertions.check(skeleton.find_bone(bone_name) >= 0, 'the rig names a "%s" bone' % bone_name)
	var seen := 0
	for mesh in _meshes(avatar.get_node_or_null("Grip")):
		seen += 1
		_assertions.check(mesh.skin == null, "Grip mesh %s carries no skin, so it rides its socket" % mesh.name)
	_assertions.check(seen > 0, "the Grip subtree contributes meshes to check, got %d" % seen)
	avatar.queue_free()


func _test_a_bare_avatar_grips_nothing_until_a_sword_arrives() -> void:
	var avatar := _spawn(4)
	_assertions.check(_visible_grip_nodes(avatar).is_empty(), "a freshly instanced avatar holds nothing, got [%s]" % ", ".join(_visible_grip_nodes(avatar)))
	_equip(avatar, [GripDefs.GRIP_HAND], ["sword"])
	_assertions.check(
		avatar.visual().gripped(GripDefs.GRIP_HAND) == "sword" and avatar.visual().gripped(GripDefs.OFF_HAND) == "",
		"a sword restatement fills only the grip hand",
	)
	_assertions.check(
		_visible_grip_nodes(avatar) == PackedStringArray(["right hand/sword"]),
		"and exactly one grip node is drawn, got [%s]" % ", ".join(_visible_grip_nodes(avatar)),
	)
	avatar.queue_free()


func _test_an_empty_restatement_clears_both_hands() -> void:
	var avatar := _spawn(5)
	_equip(avatar, [GripDefs.OFF_HAND, GripDefs.GRIP_HAND], ["shield", "sword"])
	_assertions.check(
		_visible_grip_nodes(avatar) == PackedStringArray(["left hand/shield", "right hand/sword"]),
		"sword and shield fill both hands, got [%s]" % ", ".join(_visible_grip_nodes(avatar)),
	)
	_equip(avatar, [], [])
	_assertions.check(_visible_grip_nodes(avatar).is_empty(), "an empty restatement turns the meshes back off, got [%s]" % ", ".join(_visible_grip_nodes(avatar)))
	_assertions.check(avatar.visual().grip_style() == &"none", "and the grip returns to none")
	avatar.queue_free()


func _test_a_two_handed_kind_shows_exactly_one_mesh() -> void:
	var avatar := _spawn(7)
	for kind: String in TWO_HANDED_KINDS:
		_equip(avatar, [GripDefs.OFF_HAND, GripDefs.GRIP_HAND], [kind, kind])
		_assertions.check(
			_visible_grip_nodes(avatar) == PackedStringArray(["right hand/%s" % kind]),
			"%s in both hands draws only right hand/%s, got [%s]" % [kind, kind, ", ".join(_visible_grip_nodes(avatar))],
		)
		_assertions.check(avatar.visual().grip_style() == &"two", "and grips %s two-handed" % kind)
	_equip(avatar, [GripDefs.OFF_HAND, GripDefs.GRIP_HAND], ["shield", "sword"])
	_assertions.check(_visible_grip_nodes(avatar).size() == 2, "a one-handed pair after a two-handed kind draws two meshes")
	avatar.queue_free()


func _test_a_knight_kit_shows_its_pieces_and_hides_the_regions_they_cover() -> void:
	var avatar := _spawn(6)
	var skeleton := avatar.get_node("Body/Rig/Skeleton3D") as Skeleton3D
	_equip(
		avatar,
		["helmet", "chest", "trousers", GripDefs.OFF_HAND, GripDefs.GRIP_HAND],
		["plate_helm", "plate_chest", "plate_legs", "shield", "sword"],
	)
	var shown := PackedStringArray()
	var hidden := PackedStringArray()
	for child in skeleton.get_children():
		var mesh := child as MeshInstance3D
		if mesh == null:
			continue
		if String(mesh.name).begins_with("region_") and not mesh.visible:
			hidden.append(String(mesh.name).trim_prefix("region_"))
		elif not String(mesh.name).begins_with("region_") and mesh.visible:
			shown.append(String(mesh.name))
	shown.sort()
	hidden.sort()
	_assertions.check(
		shown == PackedStringArray(["plate_chest", "plate_helm", "plate_legs"]),
		"the knight kit draws exactly its three plate pieces, got %s" % shown,
	)
	_assertions.check(
		hidden == PackedStringArray(["forearms", "head", "hips", "shins", "thighs", "torso", "upper_arms"]),
		"and hides every region the plate covers, leaving hands and feet, got %s" % hidden,
	)
	_equip(avatar, [], [])
	for child in skeleton.get_children():
		var mesh := child as MeshInstance3D
		if mesh != null:
			_assertions.check(
				mesh.visible == String(mesh.name).begins_with("region_"),
				"unequipping restores the bare body at %s" % mesh.name,
			)
	avatar.queue_free()


func _test_every_tool_reads_against_a_player_sized_avatar() -> void:
	var avatar := _spawn(9)
	var skeleton := avatar.get_node_or_null("Body/Rig/Skeleton3D") as Skeleton3D
	_assertions.check(skeleton != null, "the scale check has a rig to drive")
	if skeleton == null:
		avatar.queue_free()
		return
	var kinds := ClassDefs.tool_kinds(ClassDefs.load_sets())
	var measured := 0
	for hand: String in _hands:
		for kind: String in kinds:
			_equip(avatar, [hand], [kind])
			skeleton.force_update_all_bone_transforms()
			(avatar.get_node(NodePath("Grip/%s" % hand)) as Node3D).call("_follow_bone")
			var bounds := _drawn_bounds(avatar, hand)
			_assertions.check(not bounds.is_empty(), "%s draws a mesh in the %s socket to measure" % [kind, hand])
			if bounds.is_empty():
				continue
			var extent := maxf(bounds[0].size.x, maxf(bounds[0].size.y, bounds[0].size.z))
			_assertions.check(
				extent >= MIN_TOOL_EXTENT and extent <= MAX_TOOL_EXTENT,
				"%s spans %.3f u beside a %.1f u player, inside %.2f..%.2f" % [kind, extent, PLAYER_HEIGHT, MIN_TOOL_EXTENT, MAX_TOOL_EXTENT],
			)
			var socket := (avatar.get_node(NodePath("Grip/%s" % hand)) as Node3D).global_position
			var escape := _distance_outside(bounds[0], socket)
			_assertions.check(
				escape <= MAX_SOCKET_ESCAPE,
				"the %s socket sits %.3f u outside the %s bounds, within %.2f u, so the fist is on the tool" % [hand, escape, kind, MAX_SOCKET_ESCAPE],
			)
			measured += 1
	_assertions.check(measured == kinds.size() * SOCKET_COUNT, "every tool kind was measured in both sockets, got %d" % measured)
	avatar.queue_free()


func _test_a_detached_body_leaves_the_socket_where_it_was() -> void:
	var avatar := _spawn(10)
	var body := avatar.get_node_or_null("Body") as Node3D
	var skeleton := avatar.get_node_or_null("Body/Rig/Skeleton3D") as Skeleton3D
	_assertions.check(body != null and skeleton != null, "the detach check has a body and a rig to remove")
	if body == null or skeleton == null:
		avatar.queue_free()
		return
	var bone := skeleton.find_bone("hand_r")
	var socket := avatar.get_node("Grip/right hand") as Node3D
	_equip(avatar, [GripDefs.GRIP_HAND], ["sword"])
	var animation := avatar.get_node("AnimationPlayer") as AnimationPlayer
	animation.pause()
	var rest := skeleton.get_bone_pose_position(bone)
	await get_tree().process_frame
	var resting := socket.global_transform

	skeleton.set_bone_pose_position(bone, rest + DETACH_BONE_SHIFT)
	await get_tree().process_frame
	var driven := socket.global_transform
	_assertions.check(
		driven.origin.distance_to(resting.origin) > REACH_FLOOR,
		"a %.2f u bone shift moves the attached socket %.4f u" % [DETACH_BONE_SHIFT.length(), driven.origin.distance_to(resting.origin)],
	)

	avatar.remove_child(body)
	skeleton.set_bone_pose_position(bone, rest)
	await get_tree().process_frame
	_assertions.check_near(
		socket.global_transform.origin.distance_to(driven.origin),
		0.0,
		DETACH_DRIFT_EPSILON,
		"a socket whose body has left the tree holds its last pose",
	)
	avatar.add_child(body)
	avatar.queue_free()


func _test_an_equipment_frame_arms_the_local_avatar() -> void:
	var root := MainScene.instantiate() as Node3D
	root.name = "GripClient"
	_world.add_child(root)
	var session := root.get_node("Session") as SessionScript
	var net := root.get_node("Session/Net") as NetClientScript
	await get_tree().process_frame
	await get_tree().process_frame

	net.ingest_text_frame(WELCOME_FRAME)
	await get_tree().process_frame
	var local := session.avatar_for(1) as PlayerAvatar
	_assertions.check(local != null, "the session hands back the local avatar after welcome")
	if local == null:
		root.queue_free()
		return
	_assertions.check(_visible_grip_nodes(local).is_empty(), "welcome leaves the local avatar empty-handed")

	net.ingest_text_frame(_equipment_frame([GripDefs.GRIP_HAND, "helmet"], ["sword", "plate_helm"]))
	await get_tree().process_frame
	_assertions.check(
		_visible_grip_nodes(local) == PackedStringArray(["right hand/sword"]),
		"an equipment frame arms the local avatar with exactly the sword, got [%s]" % ", ".join(_visible_grip_nodes(local)),
	)
	_assertions.check(local.visual().shown_pieces() == PackedStringArray(["plate_helm"]), "and draws the helm")

	net.ingest_text_frame(_equipment_frame([GripDefs.OFF_HAND, GripDefs.GRIP_HAND], ["lumberjack_axe", "lumberjack_axe"]))
	await get_tree().process_frame
	_assertions.check(
		_visible_grip_nodes(local) == PackedStringArray(["right hand/lumberjack_axe"]) and local.visual().shown_pieces().is_empty(),
		"a two-handed frame draws one axe and drops the helm, got [%s]" % ", ".join(_visible_grip_nodes(local)),
	)

	net.ingest_text_frame(WELCOME_FRAME)
	await get_tree().process_frame
	_assertions.check(
		_visible_grip_nodes(local).is_empty(),
		"a fresh welcome drops it, so a rejoin cannot show the last session's tool, got [%s]" % ", ".join(_visible_grip_nodes(local)),
	)
	root.queue_free()


func _equipment_frame(slot_names: Array, slot_kinds: Array) -> String:
	var slots := PackedStringArray()
	for index in slot_names.size():
		slots.append('{"slot":"%s","kind":"%s"}' % [slot_names[index], slot_kinds[index]])
	var worn := PackedStringArray()
	for slot: String in _worn_slots:
		worn.append('"%s"' % slot)
	return '{"equipment":{"worn":[%s],"slots":[%s]}}' % [", ".join(worn), ", ".join(slots)]


func _equip(avatar: PlayerAvatar, slot_names: Array, slot_kinds: Array) -> void:
	avatar.apply_equipment(PackedStringArray(slot_names), PackedStringArray(slot_kinds))


func _spawn(id: int) -> PlayerAvatar:
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	avatar.configure(id, TICK_MS)
	_avatars.add_child(avatar)
	return avatar


func _visible_grip_nodes(avatar: PlayerAvatar) -> PackedStringArray:
	var shown := PackedStringArray()
	for socket in avatar.get_node("Grip").get_children():
		for child in socket.get_children():
			var mounted := child as Node3D
			if mounted != null and mounted.is_visible_in_tree():
				shown.append("%s/%s" % [socket.name, mounted.name])
	return shown


func _drawn_bounds(avatar: PlayerAvatar, hand: String) -> Array[AABB]:
	var socket := avatar.get_node_or_null(NodePath("Grip/%s" % hand)) as Node3D
	if socket == null:
		return []
	var bounds := AABB()
	var merged := 0
	for child in socket.get_children():
		var mounted := child as Node3D
		if mounted == null or not mounted.visible:
			continue
		for mesh in _meshes(mounted):
			var world := mesh.global_transform * mesh.get_aabb()
			bounds = world if merged == 0 else bounds.merge(world)
			merged += 1
	if merged == 0:
		return []
	return [bounds]


static func _distance_outside(box: AABB, point: Vector3) -> float:
	var nearest := Vector3(
		clampf(point.x, box.position.x, box.end.x),
		clampf(point.y, box.position.y, box.end.y),
		clampf(point.z, box.position.z, box.end.z),
	)
	return point.distance_to(nearest)


static func _meshes(root: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if root == null:
		return found
	var mesh := root as MeshInstance3D
	if mesh != null and mesh.mesh != null:
		found.append(mesh)
	for child in root.get_children():
		found.append_array(_meshes(child))
	return found
