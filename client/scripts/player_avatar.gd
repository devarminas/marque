extends Node3D


const PolylineWalker := preload("res://scripts/polyline_walker.gd")
const TickClock := preload("res://scripts/tick_clock.gd")
const OutfitDefs := preload("res://scripts/outfit_defs.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")
const GripSocket := preload("res://scripts/grip_socket.gd")

const WALK_ANIM := "ual2/Walk_Carry"
const IDLE_ANIM := "ual2/Idle_FoldArms"
const WALK_CLIP_SPEED := 0.65

const OUTFIT_MATERIAL_PREFIXES := ["MI_Peasant", "MI_Ranger"]

static var _tinted_materials := {}

var player_id := 0

var clock: TickClock = null

@export var ground_y := 0.0

@export var face_travel_direction := true

# Linear ARM-51.
@export var turn_degrees_per_second := 540.0

var _walker: PolylineWalker = null
var _desired_yaw := 0.0
var _worn_outfit := ""

@onready var _animation: AnimationPlayer = $AnimationPlayer
@onready var _hp_label: Label3D = $HpLabel
@onready var _selection_ring: MeshInstance3D = $SelectionRing
@onready var _missing_body: MeshInstance3D = $MissingBody


func _ready() -> void:
	var skeleton := get_node_or_null("Body/Armature/Skeleton3D") as Skeleton3D
	if skeleton == null:
		push_error(
			"PlayerAvatar: the Universal Base body did not instance under"
			+ " Body/Armature/Skeleton3D; drawing it magenta"
		)
		_missing_body.visible = true
		return
	_bind_outfit_to(skeleton)


func apply_class(class_id: String) -> void:
	var outfit := get_node_or_null("Outfit") as Node3D
	if outfit == null:
		push_error("PlayerAvatar.apply_class: player_avatar.tscn authors no Outfit node")
		return
	var body := get_node_or_null("Body") as Node3D
	if body == null:
		push_error("PlayerAvatar.apply_class: no Body to fit the outfit around")
		return

	_worn_outfit = OutfitDefs.outfit_for(class_id)
	var tint := OutfitDefs.tint_for(class_id)
	var worn := OutfitDefs.parts_for(class_id)
	for part_name: String in OutfitDefs.part_names():
		var part := outfit.get_node_or_null(NodePath(part_name)) as Node3D
		if part == null:
			push_error(
				"PlayerAvatar.apply_class: player_avatar.tscn authors no Outfit/%s" % part_name
			)
			continue
		var shown := worn.has(part_name)
		part.visible = shown
		for mesh in _meshes_under(part):
			_tint_surfaces(mesh, tint if shown else Color.WHITE)

	var girth := OutfitDefs.girth_for(class_id)
	body.scale = Vector3(girth, 1.0, girth)


func worn_outfit() -> String:
	return _worn_outfit


func apply_equipment(
	worn_names: PackedStringArray,
	slot_names: PackedStringArray,
	slot_kinds: PackedStringArray,
) -> void:
	if not GripDefs.names_the_hands(worn_names):
		push_error(
			"PlayerAvatar.apply_equipment: equipment.worn does not name both hands; it lists [%s]"
			% ", ".join(worn_names)
		)
		return
	var plan := GripDefs.grip_plan(slot_names, slot_kinds)
	for hand: String in GripDefs.hands():
		var socket := _grip_socket(hand)
		if socket == null:
			continue
		socket.show_kind(String(plan[hand]))


func clear_grip() -> void:
	for hand: String in GripDefs.hands():
		var socket := _grip_socket(hand)
		if socket == null:
			continue
		socket.show_kind("")


func gripped(worn: String) -> String:
	var socket := _grip_socket(worn)
	return "" if socket == null else socket.shown_kind()


func visible_grip_nodes() -> PackedStringArray:
	var shown := PackedStringArray()
	var grip := get_node_or_null("Grip") as Node3D
	if grip == null:
		push_error("PlayerAvatar.visible_grip_nodes: player_avatar.tscn authors no Grip node")
		return shown
	for socket in grip.get_children():
		for child in socket.get_children():
			var mounted := child as Node3D
			if mounted != null and mounted.is_visible_in_tree():
				shown.append("%s/%s" % [socket.name, mounted.name])
	return shown


func grip_transform(worn: String) -> Transform3D:
	var socket := _grip_socket(worn)
	return Transform3D.IDENTITY if socket == null else socket.global_transform


func configure(id: int, tick_ms: int) -> void:
	if id <= 0:
		push_error("PlayerAvatar.configure: player ids start at 1, got %d" % id)
		return
	player_id = id
	_walker = PolylineWalker.new(tick_ms)


func teleport_to(x: float, z: float) -> void:
	position = Vector3(x, ground_y, z)


func set_hit_points(hp: int, max_hp: int) -> void:
	if _hp_label == null:
		return
	_hp_label.text = "%d/%d" % [hp, max_hp]
	_hp_label.visible = true


func clear_hit_points() -> void:
	if _hp_label == null:
		return
	_hp_label.text = ""
	_hp_label.visible = false


func set_selected(on: bool) -> void:
	if _selection_ring == null:
		return
	_selection_ring.visible = on


func is_selected() -> bool:
	return _selection_ring != null and _selection_ring.visible


func follow_path(points: PackedVector2Array, start_tick: int, speed: float) -> void:
	if _walker == null:
		push_error("PlayerAvatar.follow_path: configure() was never called")
		return
	_walker.set_path(points, start_tick, speed)


func update_to_tick(tick: int) -> void:
	if _walker == null or not _walker.has_path():
		_set_walking(false)
		return

	var ground := _walker.position_at_tick(tick)
	position = Vector3(ground.x, ground_y, ground.y)
	_set_walking(not _walker.is_finished_at_tick(tick))

	if not face_travel_direction:
		return
	var heading := _walker.direction_at_tick(tick)
	if heading == Vector2.ZERO:
		return
	_desired_yaw = _yaw_facing(heading)


func is_idle_at_tick(tick: int) -> bool:
	if _walker == null:
		return true
	return _walker.is_finished_at_tick(tick)


func _process(delta: float) -> void:
	if clock != null and clock.is_anchored():
		update_to_tick(clock.estimated_tick())
	if face_travel_direction:
		_turn_toward_desired_yaw(delta)


func _set_walking(walking: bool) -> void:
	if walking:
		if _animation.current_animation != WALK_ANIM:
			_animation.play(WALK_ANIM)
		_animation.speed_scale = _walker.speed() / WALK_CLIP_SPEED
		return
	if _animation.current_animation != IDLE_ANIM:
		_animation.play(IDLE_ANIM)
	_animation.speed_scale = 1.0


func _grip_socket(worn: String) -> GripSocket:
	var socket := get_node_or_null(NodePath("Grip/%s" % worn)) as GripSocket
	if socket == null:
		push_error("PlayerAvatar: player_avatar.tscn authors no Grip/%s socket" % worn)
	return socket


func _bind_outfit_to(skeleton: Skeleton3D) -> void:
	var outfit := get_node_or_null("Outfit") as Node3D
	if outfit == null:
		push_error("PlayerAvatar: player_avatar.tscn authors no Outfit node")
		return
	for mesh in _meshes_under(outfit):
		mesh.skeleton = mesh.get_path_to(skeleton)


static func _meshes_under(root: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	var mesh := root as MeshInstance3D
	if mesh != null:
		found.append(mesh)
	for child in root.get_children():
		found.append_array(_meshes_under(child))
	return found


static func _tint_surfaces(mesh: MeshInstance3D, tint: Color) -> void:
	if mesh.mesh == null:
		return
	for surface in mesh.mesh.get_surface_count():
		var source := mesh.mesh.surface_get_material(surface)
		if source == null or not _is_outfit_material(source):
			continue
		if tint == Color.WHITE:
			mesh.set_surface_override_material(surface, null)
			continue
		mesh.set_surface_override_material(surface, _tinted_material(source, tint))


static func _is_outfit_material(source: Material) -> bool:
	for prefix: String in OUTFIT_MATERIAL_PREFIXES:
		if source.resource_name.begins_with(prefix):
			return true
	return false


static func _tinted_material(source: Material, tint: Color) -> Material:
	var by_tint: Dictionary = _tinted_materials.get(source, {})
	var cached: Material = by_tint.get(tint)
	if cached != null:
		return cached
	var tinted := source.duplicate() as BaseMaterial3D
	if tinted == null:
		push_error(
			"PlayerAvatar: outfit material %s is not a BaseMaterial3D, so it cannot be tinted"
			% source.resource_name
		)
		return source
	tinted.albedo_color = tint
	by_tint[tint] = tinted
	_tinted_materials[source] = by_tint
	return tinted


func _turn_toward_desired_yaw(delta: float) -> void:
	rotation.y = rotate_toward(
		rotation.y, _desired_yaw, deg_to_rad(turn_degrees_per_second) * delta
	)


static func _yaw_facing(heading: Vector2) -> float:
	return atan2(-heading.x, -heading.y)
