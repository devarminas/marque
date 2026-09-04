extends Node3D

## One remote player's body. Instanced once per player id by the wiring unit.
##
## The scene is [code]res://scenes/player_avatar.tscn[/code]. Its existence is
## genuine runtime behaviour — how many players are online is not known until
## runtime — so instancing it in script is the case CLAUDE.md's scene-authoring
## rule explicitly allows. Its [i]contents[/i] are authored in the scene.
##
## This node is the only place in the movement path that touches the visual
## tree. It reads a position out of a [code]polyline_walker.gd[/code] and writes
## it to a transform. The walker never reaches the other way (CLAUDE.md).
##
## Usage from the wiring unit:
##
## [codeblock]
## const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
##
## var avatar := PlayerAvatarScene.instantiate()
## avatar.configure(player_id, welcome_tick_ms)
## avatar.clock = tick_clock          # optional; see the member's docs
## remote_players.add_child(avatar)   # /root/Main/RemotePlayers
## avatar.teleport_to(spawn_x, spawn_z)
## avatar.follow_path(points, start_tick, speed)
## [/codeblock]

const PolylineWalker := preload("res://scripts/polyline_walker.gd")
const TickClock := preload("res://scripts/tick_clock.gd")

## Probed stride match: Running_A's cycle moves the feet 0.7391 units in 0.8s,
## so at 3.25x playback the stride paces the server's 3.0 units per second.
## Walking_A would need roughly 8x and slides at that rate.
const WALK_ANIM := "kaykit/Running_A"
## KayKit Idle_A: the pack's breathing idle, probed at an 8.4-degree peak leg
## swing, the subtle stance standing in place wants. Jump_Idle is a hover pose
## and Idle_B a 45-degree look-around fidget.
const IDLE_ANIM := "kaykit/Idle_A"
const WALK_SPEED_SCALE := 3.25

## Server player id, or 0 before [method configure]. Ids are assigned from 1
## (PROTOCOL.md, "Identity"), so 0 means unconfigured.
var player_id := 0

## Optional [code]tick_clock.gd[/code]. Assigned, the avatar advances itself
## every frame and the owner only has to hand it paths. Left null, the owner
## must call [method update_to_tick] itself; that is what the headless tests do,
## because a fed tick is deterministic and a read clock is not.
##
## Not [code]@export[/code]ed: a [RefCounted] is not a [Resource] and cannot be
## an exported property, and the clock is per-connection state that no scene
## should be able to author.
var clock: TickClock = null

## Y the avatar's feet sit at. [code]y[/code] never appears on the wire and is
## the client's business (PROTOCOL.md, "Coordinates"); on M0's flat plane it is
## a constant. It becomes a ground query once there is terrain.
@export var ground_y := 0.0

## Whether the body turns to face its direction of travel.
##
## Pure feel, and separable on purpose: position is protocol, facing is not.
## Turning it off changes nothing about where the avatar is.
@export var face_travel_direction := true

## How fast the body swings toward its heading. Feel, parked as Linear ARM-51.
@export var turn_degrees_per_second := 540.0

var _walker: PolylineWalker = null
## Heading the body is turning toward, in radians of Y rotation. Held separately
## from [member Node3D.rotation] so the turn can be damped over frames while the
## position stays exactly where the walker says it is.
var _desired_yaw := 0.0

## The scene's animation mixer, driving the Knight instanced below it.
@onready var _animation: AnimationPlayer = $AnimationPlayer


## Binds this avatar to a player id and to the connection's tick length.
##
## Must be called before [method follow_path]. [param tick_ms] is
## [code]welcome.tick_ms[/code]; it is constant for the life of a connection.
func configure(id: int, tick_ms: int) -> void:
	if id <= 0:
		push_error("PlayerAvatar.configure: player ids start at 1, got %d" % id)
		return
	player_id = id
	_walker = PolylineWalker.new(tick_ms)


## Places the avatar at ground-plane [code](x, z)[/code] with no interpolation.
##
## For [code]spawn[/code] and for the positions in [code]welcome[/code], which
## are stated positions rather than movement.
func teleport_to(x: float, z: float) -> void:
	position = Vector3(x, ground_y, z)


## Adopts a [code]path[/code] message. Replaces any current path outright.
##
## [param points] are ground-plane [code](x, z)[/code] waypoints,
## [param start_tick] the tick [code]points[0][/code] was current at, and
## [param speed] world units per second.
func follow_path(points: PackedVector2Array, start_tick: int, speed: float) -> void:
	if _walker == null:
		push_error("PlayerAvatar.follow_path: configure() was never called")
		return
	_walker.set_path(points, start_tick, speed)


## Moves the body to where the walker says it is at [param tick].
##
## Idempotent and order-free: the position is computed from the tick, never
## accumulated, so calling it twice with the same tick or skipping ticks
## entirely both land in the right place.
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
		# The walk is over. Hold the last heading rather than snapping to a
		# default; a body that spins on arrival reads as a bug.
		return
	_desired_yaw = _yaw_facing(heading)


## True once the avatar has arrived, or when it has no path to walk.
func is_idle_at_tick(tick: int) -> bool:
	if _walker == null:
		return true
	return _walker.is_finished_at_tick(tick)


func _process(delta: float) -> void:
	if clock != null and clock.is_anchored():
		update_to_tick(clock.estimated_tick())
	if face_travel_direction:
		_turn_toward_desired_yaw(delta)


## The walk/idle pair is derived from the walker, never stored: the tick is the
## statement of whether this player is moving, and re-deriving it keeps a
## stale "walking" flag from outliving the tick it came from. Playing the
## current animation again does not restart it (probed: position continued), so
## re-calling every update is safe and keeps the stride scale pinned.
func _set_walking(walking: bool) -> void:
	if walking:
		if _animation.current_animation != WALK_ANIM:
			_animation.play(WALK_ANIM)
		_animation.speed_scale = WALK_SPEED_SCALE
		return
	if _animation.current_animation != IDLE_ANIM:
		_animation.play(IDLE_ANIM)
	_animation.speed_scale = 1.0


func _turn_toward_desired_yaw(delta: float) -> void:
	rotation.y = rotate_toward(
		rotation.y, _desired_yaw, deg_to_rad(turn_degrees_per_second) * delta
	)


## Y rotation that points the body's forward axis along ground [param heading].
##
## A [Node3D]'s forward is local -Z. Rotating by yaw puts that axis at
## [code](-sin yaw, -cos yaw)[/code] on the ground plane, so matching it to
## [code](heading.x, heading.y)[/code] gives the [method @GlobalScope.atan2]
## below. [param heading]'s [code]y[/code] is world Z.
static func _yaw_facing(heading: Vector2) -> float:
	return atan2(-heading.x, -heading.y)
