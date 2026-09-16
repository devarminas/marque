extends Node


const ArtContract := preload("res://scripts/art_contract.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const ClipDirector := preload("res://scripts/clip_director.gd")
const GearLook := preload("res://scripts/gear_look.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")
const GripSocket := preload("res://scripts/grip_socket.gd")
const SteerIntegrate := preload("res://scripts/steer_integrate.gd")
const WeaponDefs := preload("res://scripts/weapon_defs.gd")

const LIBRARY := "proto"
const SKELETON_PATH := "Rig/Skeleton3D"
const REGION_PREFIX := "region_"
const BLEND_SEC := 0.1

static var _contract: ArtContract = null
static var _sets := {}
static var _attack_period_ticks := {}

@export var variant := "human"
@export var body: Node3D
@export var animation_player: AnimationPlayer
@export var grip: Node3D
@export var worn_slots := PackedStringArray()
@export var worn_kinds := PackedStringArray()

var _skeleton: Skeleton3D = null
var _director: ClipDirector = null
var _look: GearLook.Look = GearLook.Look.new()
var _clip := ""


static func contract() -> ArtContract:
	if _contract == null:
		_contract = ArtContract.new(ArtContract.read_text(ArtContract.PATH))
		if not _contract.is_valid():
			push_error("CharacterVisual: the art contract is invalid: %s" % [_contract.errors])
		_sets = ClassDefs.load_sets()
		_attack_period_ticks = WeaponDefs.load_attack_period_ticks()
	return _contract


func _ready() -> void:
	var art := contract()
	if body != null and body.is_inside_tree():
		_skeleton = body.get_node_or_null(SKELETON_PATH) as Skeleton3D
	if _skeleton == null or animation_player == null:
		push_error("CharacterVisual %s: needs a body with %s and an AnimationPlayer" % [get_path(), SKELETON_PATH])
		return
	_skeleton.motion_scale = art.motion_scale(variant)
	_director = ClipDirector.new(art, SteerIntegrate.WALK_SPEED * art.motion_scale(variant))
	wear(worn_slots, worn_kinds)


func _process(delta: float) -> void:
	if _director != null:
		_apply(_director.advance(delta))


func wear(slot_names: PackedStringArray, slot_kinds: PackedStringArray) -> void:
	if _director == null:
		return
	var art := contract()
	_look = GearLook.resolve(slot_names, slot_kinds, art, _sets)
	for region: String in art.regions:
		(_skeleton.get_node(REGION_PREFIX + region) as Node3D).visible = not _look.hidden_regions.has(region)
	for item: String in art.pieces:
		var piece := _skeleton.get_node_or_null(item) as Node3D
		if piece != null:
			piece.visible = _look.pieces.has(item)
		elif _look.pieces.has(item):
			push_error("CharacterVisual %s: the %s body has no %s piece to show" % [get_path(), variant, item])
	for hand: String in GripDefs.hands():
		_show_in_hand(hand, _look.hands[hand])
	_director.set_grip(_look.grip)
	_apply(_director.advance(0.0))


func locomote(ground_speed: float) -> void:
	if _director == null:
		return
	_director.locomote(ground_speed)
	_apply(_director.advance(0.0))


func elevate(clearance: float) -> void:
	if _director == null:
		return
	_director.elevate(clearance)
	_apply(_director.advance(0.0))


func swing(weapon: String, tick_ms: int) -> void:
	if _director == null:
		return
	if not _attack_period_ticks.has(weapon) or tick_ms <= 0:
		push_error("CharacterVisual %s: swing needs a known weapon and tick_ms, got %s and %d" % [get_path(), weapon, tick_ms])
	_director.swing(_attack_period_ticks.get(weapon, 0) * tick_ms / 1000.0)
	_apply(_director.advance(0.0))


func current_clip() -> String:
	return _clip


func shown_pieces() -> PackedStringArray:
	return _look.pieces


func hidden_regions() -> PackedStringArray:
	return _look.hidden_regions


func gripped(hand: String) -> String:
	return _look.hands.get(hand, "")


func grip_style() -> StringName:
	return _look.grip


func _show_in_hand(hand: String, kind: String) -> void:
	if grip == null:
		if not kind.is_empty():
			push_error("CharacterVisual %s: the %s body has no grip to hold %s" % [get_path(), variant, kind])
		return
	(grip.get_node(hand) as GripSocket).show_kind(kind)


func _apply(choice: ClipDirector.Choice) -> void:
	if choice.clip != _clip or choice.restart:
		animation_player.play("%s/%s" % [LIBRARY, choice.clip], BLEND_SEC)
		if choice.restart:
			animation_player.seek(0.0, true)
		_clip = choice.clip
	animation_player.speed_scale = choice.speed_scale
