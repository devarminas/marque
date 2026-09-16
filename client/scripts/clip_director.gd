extends RefCounted


const ArtContract := preload("res://scripts/art_contract.gd")
const GearLook := preload("res://scripts/gear_look.gd")

const IDLE := &"idle"
const WALK := &"walk"
const SWING := &"swing"
const JUMP_START := &"jump_start"
const FALL := &"fall"
const CAST_WINDUP := &"cast_windup"
const CAST_RELEASE := &"cast_release"

const PHASE_BEGIN := "begin"
const PHASE_RESOLVE := "resolve"
const PHASE_CANCEL := "cancel"

enum Mode { ONE_SHOT, AIR_LAUNCH, AIR_FALL, CHANNEL, MOVING, ALWAYS }

const LAYERS := [
	{"action": SWING, "mode": Mode.ONE_SHOT},
	{"action": CAST_RELEASE, "mode": Mode.ONE_SHOT},
	{"action": JUMP_START, "mode": Mode.AIR_LAUNCH},
	{"action": FALL, "mode": Mode.AIR_FALL},
	{"action": CAST_WINDUP, "mode": Mode.CHANNEL},
	{"action": WALK, "mode": Mode.MOVING},
	{"action": IDLE, "mode": Mode.ALWAYS},
]

const MOVING_SPEED := 0.05

const AIR_ENTER := 0.12
const AIR_EXIT := AIR_ENTER / 3.0


class Choice:
	extends RefCounted
	var clip := ""
	var speed_scale := 1.0
	var restart := false


var _contract: ArtContract
var _reference_speed := 0.0
var _grip := GearLook.GRIP_NONE
var _ground_speed := 0.0
var _airborne := false
var _channel := ""
var _one_shots := {}
var _restarted := &""


func _init(contract: ArtContract, reference_speed: float) -> void:
	_contract = contract
	_reference_speed = reference_speed
	if reference_speed <= 0.0:
		push_error("clip_director: reference_speed must be positive, got %f" % reference_speed)


func set_grip(grip: StringName) -> void:
	_grip = grip


func locomote(ground_speed: float) -> void:
	_ground_speed = ground_speed


func elevate(clearance: float) -> void:
	if _airborne:
		if clearance <= AIR_EXIT:
			_airborne = false
			_one_shots.erase(JUMP_START)
	elif clearance > AIR_ENTER:
		_airborne = true
		_play_once(JUMP_START, _grip, 1.0)


func airborne() -> bool:
	return _airborne


func swing(attack_period_sec: float) -> void:
	_play_once(SWING, _grip, _swing_speed(attack_period_sec))


func cast_phase(phase: String, ability: String) -> void:
	match phase:
		PHASE_BEGIN:
			_channel = ability
		PHASE_RESOLVE:
			_end_channel_for(ability)
			_play_once(CAST_RELEASE, ability, 1.0)
		PHASE_CANCEL:
			_end_channel_for(ability)
		_:
			push_error('clip_director: unknown cast phase "%s" for ability %s' % [phase, ability])


func channelling() -> String:
	return _channel


func advance(dt: float) -> Choice:
	for action: StringName in _one_shots.keys():
		var shot: Dictionary = _one_shots[action]
		shot["left"] -= dt * shot["speed"]
		if shot["left"] <= 0.0:
			_one_shots.erase(action)
	for layer: Dictionary in LAYERS:
		if _active(layer):
			return _choose(layer)
	return null


func _end_channel_for(ability: String) -> void:
	if _channel == ability:
		_channel = ""


func _swing_speed(period_sec: float) -> float:
	if period_sec <= 0.0:
		push_error("clip_director: swing needs a positive period, got %f" % period_sec)
		return 1.0
	return maxf(1.0, _contract.clip_length(_contract.clip_for(SWING, _grip)) / period_sec)


func _play_once(action: StringName, key: String, speed: float) -> void:
	var length := _contract.clip_length(_contract.clip_for(action, key))
	_one_shots[action] = {"left": length, "speed": speed, "key": key}
	_restarted = action


func _active(layer: Dictionary) -> bool:
	match layer["mode"]:
		Mode.ONE_SHOT:
			return _one_shots.has(layer["action"])
		Mode.AIR_LAUNCH:
			return _airborne and _one_shots.has(JUMP_START)
		Mode.AIR_FALL:
			return _airborne
		Mode.CHANNEL:
			return not _channel.is_empty()
		Mode.MOVING:
			return _ground_speed > MOVING_SPEED
	return true


func _choose(layer: Dictionary) -> Choice:
	var action: StringName = layer["action"]
	var mode: Mode = layer["mode"]
	var choice := Choice.new()
	choice.clip = _contract.clip_for(action, _key_for(mode, action))
	match mode:
		Mode.ONE_SHOT, Mode.AIR_LAUNCH:
			choice.speed_scale = _one_shots[action]["speed"]
			choice.restart = _restarted == action
		Mode.MOVING:
			choice.speed_scale = _ground_speed / _reference_speed
	_restarted = &""
	return choice


func _key_for(mode: Mode, action: StringName) -> String:
	match mode:
		Mode.ONE_SHOT, Mode.AIR_LAUNCH:
			return _one_shots[action]["key"]
		Mode.CHANNEL:
			return _channel
	return _grip
