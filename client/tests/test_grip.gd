extends Node3D


const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const PlayerAvatar := preload("res://scripts/player_avatar.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const Assertions := preload("res://tests/assertions.gd")

const TICK_MS := 100
const SOCKET_COUNT := 2
const TWO_HANDED_KINDS := ["staff", "bow", "lumberjack_axe"]
const DRESSED_CLASS := "knight"
const HAND_BONES := {"left hand": "hand_l", "right hand": "hand_r"}

const REACH_FLOOR := 0.2
const GIRTH_EPSILON := 1.0e-4
const PLAYER_HEIGHT := 1.7
const MIN_TOOL_EXTENT := 0.25
const MAX_TOOL_EXTENT := 2.2
const MAX_SOCKET_ESCAPE := 0.1
const DETACH_BONE_SHIFT := Vector3(0.0, 0.5, 0.0)
const DETACH_DRIFT_EPSILON := 1.0e-4
const SLEEVE_PART := "RangerArms"
const SLEEVE_BONE_SHIFT := Vector3(0.0, 0.35, 0.0)
const SLEEVE_EPSILON := 1.0e-3

const WELCOME_FRAME := (
	'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
	+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100}]}}'
)

@onready var _avatars: Node3D = $Avatars
@onready var _world: Node3D = $World

var _assertions: Assertions = null
var _finished := false
var _hands := GripDefs.hands()
var _worn_slots := PackedStringArray(
	["helmet", "left hand", "chest", "right hand", "feet", "trousers"]
)


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures if _assertions != null else PackedStringArray()


func get_assertion_count() -> int:
	return _assertions.assertion_count if _assertions != null else 0


func _ready() -> void:
	_assertions = Assertions.new()

	_test_the_sockets_author_every_tool_the_server_ships()
	_test_the_player_attach_path_names_no_kaykit_asset()
	_test_the_rig_carries_both_hand_bones()
	_test_a_bare_avatar_grips_nothing_until_a_sword_arrives()
	_test_an_empty_restatement_clears_both_hands()
	_test_a_worn_list_without_hands_is_refused()
	_test_a_two_handed_kind_shows_exactly_one_mesh()
	await _test_the_socket_ignores_the_dressed_girth()
	_test_every_tool_reads_against_a_player_sized_avatar()
	await _test_a_detached_body_leaves_the_socket_where_it_was()
	await _test_an_equipment_frame_arms_the_local_avatar()

	_finished = true


func _test_the_sockets_author_every_tool_the_server_ships() -> void:
	var avatar := _spawn(1)
	var kinds := ClassDefs.tool_kinds(ClassDefs.load_sets())
	_assertions.check(
		kinds.size() > 0,
		"shared/sets.json resolved %d tool kind(s) through class_defs.gd" % kinds.size(),
	)

	var grip := avatar.get_node_or_null("Grip") as Node3D
	_assertions.check(grip != null, "player_avatar.tscn authors a Grip node")
	if grip == null:
		avatar.queue_free()
		return
	_assertions.check(
		grip.get_child_count() == SOCKET_COUNT,
		"Grip authors exactly the two hand sockets, got %d" % grip.get_child_count(),
	)

	var checked := 0
	for hand: String in _hands:
		var socket := grip.get_node_or_null(NodePath(hand)) as Node3D
		_assertions.check(socket != null, 'Grip authors a "%s" socket' % hand)
		if socket == null:
			continue
		var authored := PackedStringArray()
		for child in socket.get_children():
			authored.append(String(child.name))
		authored.sort()
		_assertions.check(
			authored == kinds,
			"the %s socket authors exactly the server's tool kinds; sets.json ships [%s],"
			% [hand, ", ".join(kinds)]
			+ " the socket authors [%s]" % ", ".join(authored),
		)
		checked += 1
	_assertions.check(
		checked == SOCKET_COUNT, "both sockets were compared, got %d" % checked
	)

	avatar.queue_free()


func _test_the_player_attach_path_names_no_kaykit_asset() -> void:
	var avatar := _spawn(2)
	var paths := _resource_paths_under(avatar.get_node_or_null("Grip"))
	_assertions.check(
		paths.size() > 0,
		"the Grip subtree names %d asset resource(s), so this scan cannot pass vacuously"
		% paths.size(),
	)
	for path: String in paths:
		_assertions.check(
			not path.to_lower().contains("kaykit"),
			"the player attach path draws %s, which is not a kaykit asset" % path,
		)

	avatar.queue_free()


func _test_the_rig_carries_both_hand_bones() -> void:
	var avatar := _spawn(3)
	var skeleton := avatar.get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
	_assertions.check(skeleton != null, "the base body still carries the shared rig")
	if skeleton == null:
		avatar.queue_free()
		return

	for bone_name: String in ["hand_l", "hand_r"]:
		_assertions.check(
			skeleton.find_bone(bone_name) >= 0,
			'the rig names a "%s" bone, got index %d' % [bone_name, skeleton.find_bone(bone_name)],
		)
	_assertions.check_near(
		skeleton.motion_scale,
		1.0,
		1.0e-6,
		"the rig's motion_scale is 1.0, so a bone pose is already in metres",
	)

	var seen := 0
	var swept := 0
	for mesh in _meshes(avatar.get_node_or_null("Grip")):
		seen += 1
		if mesh.get_node_or_null(mesh.skeleton) == skeleton:
			swept += 1
		_assertions.check(
			mesh.skin == null,
			"Grip mesh %s carries no skin, so it rides its own grip transform" % mesh.name,
		)
	_assertions.check(
		seen > 0, "the Grip subtree contributes meshes to check, got %d" % seen
	)
	_assertions.check(
		swept == 0,
		"_bind_outfit_to left all %d Grip mesh(es) unbound; %d were swept onto the rig"
		% [seen, swept],
	)

	avatar.queue_free()


func _test_a_bare_avatar_grips_nothing_until_a_sword_arrives() -> void:
	var avatar := _spawn(4)
	_assertions.check(
		avatar.visible_grip_nodes().is_empty(),
		"a freshly instanced avatar holds nothing, got [%s]"
		% ", ".join(avatar.visible_grip_nodes()),
	)
	_assertions.check(
		avatar.gripped(GripDefs.OFF_HAND) == "" and avatar.gripped(GripDefs.GRIP_HAND) == "",
		"and reports both hands empty",
	)

	_equip(avatar, [GripDefs.GRIP_HAND], ["sword"])
	_assertions.check(
		avatar.gripped(GripDefs.GRIP_HAND) == "sword",
		'a sword restatement fills the grip hand, got "%s"' % avatar.gripped(GripDefs.GRIP_HAND),
	)
	_assertions.check(
		avatar.gripped(GripDefs.OFF_HAND) == "",
		'and leaves the off hand empty, got "%s"' % avatar.gripped(GripDefs.OFF_HAND),
	)
	_assertions.check(
		avatar.visible_grip_nodes() == PackedStringArray(["right hand/sword"]),
		"and exactly one grip node is drawn, got [%s]"
		% ", ".join(avatar.visible_grip_nodes()),
	)

	avatar.queue_free()


func _test_an_empty_restatement_clears_both_hands() -> void:
	var avatar := _spawn(5)
	_equip(avatar, [GripDefs.OFF_HAND, GripDefs.GRIP_HAND], ["shield", "sword"])
	_assertions.check(
		avatar.visible_grip_nodes()
		== PackedStringArray(["left hand/shield", "right hand/sword"]),
		"sword and shield fill both hands, got [%s]" % ", ".join(avatar.visible_grip_nodes()),
	)

	_equip(avatar, [], [])
	_assertions.check(
		avatar.visible_grip_nodes().is_empty(),
		"an empty restatement turns the meshes back off, got [%s]"
		% ", ".join(avatar.visible_grip_nodes()),
	)
	_assertions.check(
		avatar.gripped(GripDefs.OFF_HAND) == "" and avatar.gripped(GripDefs.GRIP_HAND) == "",
		'and both hands report "", got "%s" and "%s"'
		% [avatar.gripped(GripDefs.OFF_HAND), avatar.gripped(GripDefs.GRIP_HAND)],
	)

	_equip(avatar, [GripDefs.OFF_HAND, GripDefs.GRIP_HAND], ["shield", "sword"])
	_assertions.check(
		avatar.visible_grip_nodes()
		== PackedStringArray(["left hand/shield", "right hand/sword"]),
		"both hands are drawn again, so clear_grip below has something to clear, got [%s]"
		% ", ".join(avatar.visible_grip_nodes()),
	)

	avatar.clear_grip()
	_assertions.check(
		avatar.visible_grip_nodes().is_empty(),
		"clear_grip empties a filled grip, got [%s]" % ", ".join(avatar.visible_grip_nodes()),
	)
	_assertions.check(
		avatar.gripped(GripDefs.OFF_HAND) == "" and avatar.gripped(GripDefs.GRIP_HAND) == "",
		'and both hands report "" after it, got "%s" and "%s"'
		% [avatar.gripped(GripDefs.OFF_HAND), avatar.gripped(GripDefs.GRIP_HAND)],
	)

	avatar.clear_grip()
	_assertions.check(
		avatar.visible_grip_nodes().is_empty(), "a second clear_grip stays empty"
	)

	avatar.queue_free()


func _test_a_worn_list_without_hands_is_refused() -> void:
	print("  (the ERROR line below is a fail-closed path under test)")
	var avatar := _spawn(6)
	_equip(avatar, [GripDefs.GRIP_HAND], ["pickaxe"])
	avatar.apply_equipment(
		PackedStringArray(["helmet", "chest", "feet", "trousers"]),
		PackedStringArray(),
		PackedStringArray(),
	)
	_assertions.check(
		avatar.gripped(GripDefs.GRIP_HAND) == "pickaxe",
		"a worn list that names neither hand is refused rather than silently emptying the"
		+ ' hands, got "%s"' % avatar.gripped(GripDefs.GRIP_HAND),
	)

	avatar.queue_free()


func _test_a_two_handed_kind_shows_exactly_one_mesh() -> void:
	var avatar := _spawn(7)
	for kind: String in TWO_HANDED_KINDS:
		_equip(avatar, [GripDefs.OFF_HAND, GripDefs.GRIP_HAND], [kind, kind])
		_assertions.check(
			avatar.visible_grip_nodes() == PackedStringArray(["right hand/%s" % kind]),
			"%s in both hands draws only right hand/%s, got [%s]"
			% [kind, kind, ", ".join(avatar.visible_grip_nodes())],
		)
		_assertions.check(
			_drawn_grip_children(avatar) == 1,
			"and the whole Grip subtree holds exactly one drawn mesh for %s, got %d"
			% [kind, _drawn_grip_children(avatar)],
		)

	_equip(avatar, [GripDefs.OFF_HAND, GripDefs.GRIP_HAND], ["shield", "sword"])
	_assertions.check(
		_drawn_grip_children(avatar) == 2,
		"a one-handed pair after a two-handed kind draws two meshes, got %d"
		% _drawn_grip_children(avatar),
	)

	_equip(avatar, [GripDefs.OFF_HAND, GripDefs.GRIP_HAND], ["staff", "staff"])
	_assertions.check(
		_drawn_grip_children(avatar) == 1,
		"and back to the staff leaves exactly one drawn mesh, got %d"
		% _drawn_grip_children(avatar),
	)
	_assertions.check(
		avatar.visible_grip_nodes() == PackedStringArray(["right hand/staff"]),
		"with no shield ghost left in the off hand, got [%s]"
		% ", ".join(avatar.visible_grip_nodes()),
	)

	avatar.queue_free()


func _test_the_socket_ignores_the_dressed_girth() -> void:
	var avatar := _spawn(8)
	var skeleton := avatar.get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
	_assertions.check(skeleton != null, "the girth check has a rig to drive")
	if skeleton == null:
		avatar.queue_free()
		return

	_equip(avatar, [GripDefs.GRIP_HAND], ["sword"])
	await get_tree().process_frame
	var bare := avatar.grip_transform(GripDefs.GRIP_HAND)
	var reach := bare.origin.distance_to(avatar.global_position)
	_assertions.check(
		reach > REACH_FLOOR,
		"the bare socket sits %.4f u from the avatar origin, past the %.2f u floor, so a"
		% [reach, REACH_FLOOR]
		+ " silent find_bone failure cannot pass the next check vacuously",
	)

	avatar.apply_class(DRESSED_CLASS)
	await get_tree().process_frame
	var dressed := avatar.grip_transform(GripDefs.GRIP_HAND)
	_assertions.check_near(
		dressed.origin.distance_to(bare.origin),
		0.0,
		GIRTH_EPSILON,
		"dressing as a %s leaves the grip where the sleeve renders" % DRESSED_CLASS,
	)

	var basis_scale := dressed.basis.get_scale()
	_assertions.check(
		basis_scale.distance_to(Vector3.ONE) <= GIRTH_EPSILON,
		"the dressed girth cancels out of the socket basis, got scale %s" % basis_scale,
	)
	var x_axis := dressed.basis.x
	var y_axis := dressed.basis.y
	var z_axis := dressed.basis.z
	_assertions.check(
		absf(x_axis.dot(y_axis)) <= GIRTH_EPSILON
		and absf(y_axis.dot(z_axis)) <= GIRTH_EPSILON
		and absf(x_axis.dot(z_axis)) <= GIRTH_EPSILON,
		"and the socket basis stays orthogonal, so a held weapon is not sheared; dots %.6f"
		% absf(x_axis.dot(y_axis))
		+ ", %.6f, %.6f" % [absf(y_axis.dot(z_axis)), absf(x_axis.dot(z_axis))],
	)

	var sleeve := avatar.get_node_or_null(NodePath("Outfit/%s" % SLEEVE_PART)) as Node3D
	var sleeve_drawn := sleeve != null and sleeve.is_visible_in_tree()
	_assertions.check(
		sleeve_drawn,
		'apply_class("%s") draws Outfit/%s, so the oracle below reads the sleeve the fist'
		% [DRESSED_CLASS, SLEEVE_PART]
		+ " renders inside rather than a hidden node",
	)
	if not sleeve_drawn:
		avatar.queue_free()
		return

	for hand: String in _hands:
		var bone_name := String(HAND_BONES.get(hand, ""))
		var bone := skeleton.find_bone(bone_name)
		_assertions.check(
			bone >= 0,
			'the %s socket has a "%s" bone to drive, got index %d' % [hand, bone_name, bone],
		)
		if bone < 0:
			continue

		var undriven := avatar.grip_transform(hand)
		_assertions.check_near(
			undriven.origin.distance_to(
				(sleeve.global_transform * skeleton.get_bone_global_pose(bone)).origin
			),
			0.0,
			SLEEVE_EPSILON,
			"the resting %s socket sits where Outfit/%s renders %s"
			% [hand, SLEEVE_PART, bone_name],
		)

		skeleton.set_bone_pose_position(
			bone, skeleton.get_bone_pose_position(bone) + SLEEVE_BONE_SHIFT
		)
		await get_tree().process_frame
		var sleeve_hand := sleeve.global_transform * skeleton.get_bone_global_pose(bone)
		var socket := avatar.grip_transform(hand)

		var moved := socket.origin.distance_to(undriven.origin)
		_assertions.check(
			moved > REACH_FLOOR,
			"a %.2f u shift of %s moves the dressed %s socket %.4f u, past the %.2f u floor,"
			% [SLEEVE_BONE_SHIFT.length(), bone_name, hand, moved, REACH_FLOOR]
			+ " so the next check cannot be met by a socket nothing drives",
		)
		_assertions.check_near(
			socket.origin.distance_to(sleeve_hand.origin),
			0.0,
			SLEEVE_EPSILON,
			"and it lands where Outfit/%s renders %s, so the tool is in the sleeve's fist and"
			% [SLEEVE_PART, bone_name]
			+ " not pulled in toward the squashed skin",
		)

	avatar.queue_free()


func _test_every_tool_reads_against_a_player_sized_avatar() -> void:
	var avatar := _spawn(9)
	var skeleton := avatar.get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
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
			var bounds := _drawn_bounds(avatar, hand)
			_assertions.check(
				not bounds.is_empty(),
				"%s draws a mesh in the %s socket to measure" % [kind, hand],
			)
			if bounds.is_empty():
				continue
			var size := bounds[0].size
			var extent := maxf(size.x, maxf(size.y, size.z))
			_assertions.check(
				extent >= MIN_TOOL_EXTENT and extent <= MAX_TOOL_EXTENT,
				"%s spans %.3f u in world space beside a %.1f u player, inside the %.2f..%.2f band"
				% [kind, extent, PLAYER_HEIGHT, MIN_TOOL_EXTENT, MAX_TOOL_EXTENT],
			)
			var escape := _distance_outside(
				bounds[0], avatar.grip_transform(hand).origin
			)
			_assertions.check(
				escape <= MAX_SOCKET_ESCAPE,
				"the %s socket origin sits %.3f u outside the %s's world bounds, within the"
				% [hand, escape, kind]
				+ " %.2f u slack, so the fist is on the tool" % MAX_SOCKET_ESCAPE,
			)
			measured += 1
	_assertions.check(
		measured == kinds.size() * SOCKET_COUNT and measured > 0,
		"every one of the %d server tool kinds was measured in both sockets, got %d"
		% [kinds.size(), measured],
	)

	avatar.queue_free()


func _test_a_detached_body_leaves_the_socket_where_it_was() -> void:
	var avatar := _spawn(10)
	var body := avatar.get_node_or_null("Body") as Node3D
	var skeleton := avatar.get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
	_assertions.check(
		body != null and skeleton != null, "the detach check has a body and a rig to remove"
	)
	if body == null or skeleton == null:
		avatar.queue_free()
		return
	var bone := skeleton.find_bone("hand_r")
	_assertions.check(bone >= 0, "the detach check found hand_r, got index %d" % bone)
	if bone < 0:
		avatar.queue_free()
		return

	_equip(avatar, [GripDefs.GRIP_HAND], ["sword"])
	var rest := skeleton.get_bone_pose_position(bone)
	await get_tree().process_frame
	var resting := avatar.grip_transform(GripDefs.GRIP_HAND)

	skeleton.set_bone_pose_position(bone, rest + DETACH_BONE_SHIFT)
	await get_tree().process_frame
	var driven := avatar.grip_transform(GripDefs.GRIP_HAND)
	_assertions.check(
		driven.origin.distance_to(resting.origin) > REACH_FLOOR,
		"a %.2f u bone shift moves the attached socket %.4f u, past the %.2f u floor, so the"
		% [DETACH_BONE_SHIFT.length(), driven.origin.distance_to(resting.origin), REACH_FLOOR]
		+ " next check cannot pass on a socket nothing drives",
	)

	avatar.remove_child(body)
	skeleton.set_bone_pose_position(bone, rest)
	await get_tree().process_frame
	var detached := avatar.grip_transform(GripDefs.GRIP_HAND)
	_assertions.check_near(
		detached.origin.distance_to(driven.origin),
		0.0,
		DETACH_DRIFT_EPSILON,
		"a socket whose body has left the tree holds its last pose rather than reading a world"
		+ " transform that no longer exists",
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
	_assertions.check(
		local.visible_grip_nodes().is_empty(),
		"welcome leaves the local avatar empty-handed, got [%s]"
		% ", ".join(local.visible_grip_nodes()),
	)

	net.ingest_text_frame(_equipment_frame([GripDefs.GRIP_HAND], ["sword"]))
	await get_tree().process_frame
	_assertions.check(
		local.gripped(GripDefs.GRIP_HAND) == "sword",
		'an equipment frame arms the local avatar with no reconnect, got "%s"'
		% local.gripped(GripDefs.GRIP_HAND),
	)
	_assertions.check(
		local.visible_grip_nodes() == PackedStringArray(["right hand/sword"]),
		"and draws exactly the sword, got [%s]" % ", ".join(local.visible_grip_nodes()),
	)

	net.ingest_text_frame(_equipment_frame([], []))
	await get_tree().process_frame
	_assertions.check(
		local.visible_grip_nodes().is_empty(),
		"an empty slots frame disarms it again, got [%s]"
		% ", ".join(local.visible_grip_nodes()),
	)

	net.ingest_text_frame(
		_equipment_frame(
			[GripDefs.OFF_HAND, GripDefs.GRIP_HAND], ["lumberjack_axe", "lumberjack_axe"]
		)
	)
	await get_tree().process_frame
	_assertions.check(
		local.visible_grip_nodes() == PackedStringArray(["right hand/lumberjack_axe"]),
		"a two-handed frame off the wire draws one axe in the grip hand, got [%s]"
		% ", ".join(local.visible_grip_nodes()),
	)

	net.ingest_text_frame(WELCOME_FRAME)
	await get_tree().process_frame
	_assertions.check(
		local.visible_grip_nodes().is_empty(),
		"and a fresh welcome drops it, so a rejoin cannot show the last session's tool, got [%s]"
		% ", ".join(local.visible_grip_nodes()),
	)

	root.queue_free()


func _equipment_frame(slot_names: Array, slot_kinds: Array) -> String:
	var slots := PackedStringArray()
	for index in slot_names.size():
		slots.append('{"slot":"%s","kind":"%s"}' % [slot_names[index], slot_kinds[index]])
	var worn := PackedStringArray()
	for slot: String in _worn_slots:
		worn.append('"%s"' % slot)
	return (
		'{"equipment":{"worn":[%s],"slots":[%s]}}'
		% [", ".join(worn), ", ".join(slots)]
	)


func _equip(avatar: PlayerAvatar, slot_names: Array, slot_kinds: Array) -> void:
	avatar.apply_equipment(
		_worn_slots, PackedStringArray(slot_names), PackedStringArray(slot_kinds)
	)


func _spawn(id: int) -> PlayerAvatar:
	var avatar := PlayerAvatarScene.instantiate() as PlayerAvatar
	avatar.configure(id, TICK_MS)
	_avatars.add_child(avatar)
	return avatar


func _drawn_grip_children(avatar: PlayerAvatar) -> int:
	var grip := avatar.get_node_or_null("Grip") as Node3D
	if grip == null:
		return -1
	var drawn := 0
	for socket in grip.get_children():
		for child in socket.get_children():
			var mounted := child as Node3D
			if mounted != null and mounted.is_visible_in_tree():
				drawn += 1
	return drawn


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
	var low := box.position
	var high := box.end
	var nearest := Vector3(
		clampf(point.x, low.x, high.x),
		clampf(point.y, low.y, high.y),
		clampf(point.z, low.z, high.z),
	)
	return point.distance_to(nearest)


static func _resource_paths_under(root: Node) -> PackedStringArray:
	var paths := PackedStringArray()
	if root == null:
		return paths
	if not root.scene_file_path.is_empty():
		paths.append(root.scene_file_path)
	var mesh := root as MeshInstance3D
	if mesh != null and mesh.mesh != null:
		paths.append(mesh.mesh.resource_path)
	for child in root.get_children():
		paths.append_array(_resource_paths_under(child))
	return paths


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
