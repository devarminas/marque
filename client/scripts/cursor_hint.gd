extends Node

const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")

enum Hint {
	POINTER,
	ATTACK,
	CHOP,
	TALK,
}

const SHAPES := {
	Hint.POINTER: {
		"image": preload("res://assets/kenney_cursors/pointer_b.png"),
		"hotspot": Vector2(10, 8),
	},
	Hint.ATTACK: {
		"image": preload("res://assets/kenney_cursors/tool_sword_a.png"),
		"hotspot": Vector2(4, 4),
	},
	Hint.CHOP: {
		"image": preload("res://assets/kenney_cursors/tool_axe.png"),
		"hotspot": Vector2(13, 3),
	},
	Hint.TALK: {
		"image": preload("res://assets/kenney_cursors/gauntlet_point.png"),
		"hotspot": Vector2(3, 4),
	},
}

@export var picker: Node
@export var camera: Camera3D
@export var local_player: Node3D
@export var chrome_layer: CanvasLayer

var _picker: GroundPickerScript = null
var _hint := Hint.POINTER
var _mouse := Vector2.ZERO
var _mouse_present := false
var _dirty := false
var _over_chrome := false
var _watched: Node3D = null
var _watched_pose := Transform3D()
var _camera_pose := Transform3D()


func _ready() -> void:
	_picker = picker as GroundPickerScript
	if _picker == null or camera == null or local_player == null or chrome_layer == null:
		push_error(
			"CursorHint: the scene must assign picker, camera, local_player and chrome_layer"
		)
		set_process(false)
		set_process_input(false)
		return
	_set_cursor(_hint)


func _input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion == null:
		return
	_mouse = motion.position
	_mouse_present = true
	_dirty = true


func _process(_delta: float) -> void:
	if _dirty or _stale():
		refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_WM_MOUSE_EXIT:
		_mouse_present = false
		refresh()


func refresh() -> void:
	_dirty = false
	if _picker == null:
		return
	_camera_pose = camera.global_transform
	_over_chrome = _mouse_present and _chrome_at(_mouse)
	if not _mouse_present or _over_chrome:
		_watch(null)
		_apply(Hint.POINTER)
		return
	var picked := _picker.pick(_mouse)
	_watch(_dependency_of(picked))
	_apply(hint_for(picked, local_player))


func current_hint() -> Hint:
	return _hint


func over_chrome() -> bool:
	return _over_chrome


static func hint_for(picked: Dictionary, own_avatar: Node3D) -> Hint:
	match picked["target"]:
		GroundPickerScript.Target.NODE:
			var resource_node := picked["node"] as ResourceNodeScript
			if resource_node != null and resource_node.is_gatherable():
				return Hint.CHOP
			return Hint.POINTER
		GroundPickerScript.Target.PLAYER:
			var dummy := picked["player"] as NpcDummyScript
			if dummy != null:
				if dummy.is_talkable():
					return Hint.TALK
				if dummy.faction == NpcDummyScript.FactionHostile:
					return Hint.ATTACK
				return Hint.POINTER
			if picked["player"] == own_avatar:
				return Hint.POINTER
			return Hint.ATTACK
		_:
			return Hint.POINTER


func _stale() -> bool:
	if not _mouse_present:
		return false
	if _chrome_at(_mouse) != _over_chrome:
		return true
	if _watched_gone():
		return true
	if _watched != null and _watched.global_transform != _watched_pose:
		return true
	return camera.global_transform != _camera_pose


func _watched_gone() -> bool:
	if _watched == null:
		return false
	if not is_instance_valid(_watched):
		return true
	return not _watched.is_inside_tree()


func _watch(body: Node3D) -> void:
	_watched = body
	_watched_pose = Transform3D() if body == null else body.global_transform


func _chrome_at(at: Vector2) -> bool:
	return _chrome_under(chrome_layer, at)


static func _chrome_under(parent: Node, at: Vector2) -> bool:
	for child in parent.get_children():
		var control := child as Control
		if control != null:
			if not control.is_visible_in_tree():
				continue
			if control.get_global_rect().has_point(at):
				return true
		if _chrome_under(child, at):
			return true
	return false


func _apply(hint: Hint) -> void:
	if hint == _hint:
		return
	_hint = hint
	_set_cursor(hint)


func _set_cursor(hint: Hint) -> void:
	var row: Dictionary = SHAPES[hint]
	Input.set_custom_mouse_cursor(row["image"], Input.CURSOR_ARROW, row["hotspot"])


static func _dependency_of(picked: Dictionary) -> Node3D:
	for key in ["player", "node", "item"]:
		var body := picked[key] as Node3D
		if body != null:
			return body
	return null
