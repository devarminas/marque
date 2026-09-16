extends RefCounted


const ArtContract := preload("res://scripts/art_contract.gd")
const GearLook := preload("res://scripts/gear_look.gd")

const IDLE := &"idle"
const WALK := &"walk"
const SWING := &"swing"
const JUMP_START := &"jump_start"
const FALL := &"fall"

enum Mode { ONE_SHOT, AIR_LAUNCH, AIR_FALL, MOVING, ALWAYS }

const LAYERS := [
	{"action": SWING, "mode": Mode.ONE_SHOT},
	{"action": JUMP_START, "mode": Mode.AIR_LAUNCH},
	{"action": FALL, "mode": Mode.AIR_FALL},
	{"action": WALK, "mode": Mode.MOVING},
	{"action": IDLE, "mode": Mode.ALWAYS},
]

const MOVING_SPEED := 0.05

# Clearance above the ground under the actor, not pose y, so a ramp never reads as
# flight. ADR 0004 jumps at 5.0 m/s under gravity 20.0, so the first tick of a jump
# reaches 0.144 m at 30 Hz and 0.2 m at 20 Hz, both over AIR_ENTER. The display
# height lags the ground by far less than that on any walkable slope, and AIR_EXIT
# at a third of AIR_ENTER leaves a band no lag or pose noise can chatter across.
const AIR_ENTER := 0.12
const AIR_EXIT := 0.04


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
		_play_once(JUMP_START, 1.0)


func airborne() -> bool:
	return _airborne


func swing(attack_period_sec: float) -> void:
	_play_once(SWING, _swing_speed(attack_period_sec))


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


func _swing_speed(period_sec: float) -> float:
	if period_sec <= 0.0:
		push_error("clip_director: swing needs a positive period, got %f" % period_sec)
		return 1.0
	return maxf(1.0, _contract.clip_length(_contract.clip_for(SWING, _grip)) / period_sec)


func _play_once(action: StringName, speed: float) -> void:
	_one_shots[action] = {"left": _contract.clip_length(_contract.clip_for(action, _grip)), "speed": speed}
	_restarted = action


func _active(layer: Dictionary) -> bool:
	match layer["mode"]:
		Mode.ONE_SHOT:
			return _one_shots.has(layer["action"])
		Mode.AIR_LAUNCH:
			return _airborne and _one_shots.has(JUMP_START)
		Mode.AIR_FALL:
			return _airborne
		Mode.MOVING:
			return _ground_speed > MOVING_SPEED
	return true


func _choose(layer: Dictionary) -> Choice:
	var action: StringName = layer["action"]
	var choice := Choice.new()
	choice.clip = _contract.clip_for(action, _grip)
	match layer["mode"]:
		Mode.ONE_SHOT, Mode.AIR_LAUNCH:
			choice.speed_scale = _one_shots[action]["speed"]
			choice.restart = _restarted == action
		Mode.MOVING:
			choice.speed_scale = _ground_speed / _reference_speed
	_restarted = &""
	return choice
