extends RefCounted


const ArtContract := preload("res://scripts/art_contract.gd")
const GearLook := preload("res://scripts/gear_look.gd")

const IDLE := &"idle"
const WALK := &"walk"
const SWING := &"swing"

enum Mode { ONE_SHOT, MOVING, ALWAYS }

const LAYERS := [
	{"action": SWING, "mode": Mode.ONE_SHOT},
	{"action": WALK, "mode": Mode.MOVING},
	{"action": IDLE, "mode": Mode.ALWAYS},
]

const MOVING_SPEED := 0.05


class Choice:
	extends RefCounted
	var clip := ""
	var speed_scale := 1.0
	var restart := false


var _contract: ArtContract
var _reference_speed := 0.0
var _grip := GearLook.GRIP_NONE
var _ground_speed := 0.0
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


func swing(attack_period_sec: float) -> void:
	_play_once(SWING, attack_period_sec)


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


func _play_once(action: StringName, period_sec: float) -> void:
	var length := _contract.clip_length(_contract.clip_for(action, _grip))
	var speed := 1.0
	if period_sec > 0.0:
		speed = maxf(1.0, length / period_sec)
	else:
		push_error("clip_director: %s needs a positive period, got %f" % [action, period_sec])
	_one_shots[action] = {"left": length, "speed": speed}
	_restarted = action


func _active(layer: Dictionary) -> bool:
	match layer["mode"]:
		Mode.ONE_SHOT:
			return _one_shots.has(layer["action"])
		Mode.MOVING:
			return _ground_speed > MOVING_SPEED
	return true


func _choose(layer: Dictionary) -> Choice:
	var action: StringName = layer["action"]
	var choice := Choice.new()
	choice.clip = _contract.clip_for(action, _grip)
	match layer["mode"]:
		Mode.ONE_SHOT:
			choice.speed_scale = _one_shots[action]["speed"]
			choice.restart = _restarted == action
		Mode.MOVING:
			choice.speed_scale = _ground_speed / _reference_speed
	_restarted = &""
	return choice
