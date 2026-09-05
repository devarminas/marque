extends RefCounted

const SessionScript := preload("res://scripts/session.gd")
const TickClock := preload("res://scripts/tick_clock.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const DeathOverlayScript := preload("res://scripts/death_overlay.gd")
const HpHudScript := preload("res://scripts/hp_hud.gd")

const ROLE_ATTACKER := "attacker"
const ROLE_VICTIM := "victim"

const ATTACK_RANGE := 1.5
const MIN_SEPARATION := 2.5
const MAX_HP := 100

const SCREENSHOT_WARMUP_FRAMES := 15
const REQUIRED_PLAYERS := 2
const JOIN_TIMEOUT_MSEC := 20000
const RESTATE_TIMEOUT_MSEC := 20000
const USEC_PER_MSEC := 1000

const CLICK_LEAD_TICKS := 40
const SHOT_BEFORE_LEAD_TICKS := 6
const HOLD_AFTER_RESPAWN_TICKS := 24

const TICK_WAIT_BACKSTOP_MSEC := 120000
const SPIN_USEC := 20000
const AVATAR_CLICK_HEIGHT := 0.8
const KILL_WAIT_MSEC := 90000
const SEPARATE_WAIT_MSEC := 30000
const RELOCATE_FRACTION := Vector2(0.78, 0.72)
const POST_MOVE_FRACTION := Vector2(0.35, 0.72)

var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _death: DeathOverlayScript
var _hp_hud: HpHudScript
var _prefix: String
var _role: String
var _target_id := 0


func run(
	root: Node,
	session: SessionScript,
	death: DeathOverlayScript,
	hp_hud: HpHudScript,
	prefix: String,
	role: String,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_death = death
	_hp_hud = hp_hud
	_prefix = prefix
	_role = role

	if _role != ROLE_ATTACKER and _role != ROLE_VICTIM:
		return _fail("role '%s' is not attacker or victim" % _role)

	var scenario_usec := await _wait_for_scenario()
	if scenario_usec < 0:
		return _fail("fewer than %d player(s) after %dms" % [REQUIRED_PLAYERS, JOIN_TIMEOUT_MSEC])
	print("DEMO joined %d" % _session.own_id())
	print("DEMO role %s" % _role)

	_target_id = _other_id()
	if _target_id <= 0:
		return _fail("no other player id after join")
	print("DEMO target %d" % _target_id)

	if _role == ROLE_VICTIM:
		if not await _relocate_out_of_range():
			return 1
	else:
		if not await _wait_until(
			func() -> bool:
				return _distance_to_target() > MIN_SEPARATION,
			SEPARATE_WAIT_MSEC,
		):
			return _fail(
				"target never reached separation > %f (last dist %f)"
				% [MIN_SEPARATION, _distance_to_target()]
			)

	var clock := _session.tick_clock()
	if not clock.is_anchored():
		return _fail("the tick clock is not anchored; there is no shared moment to click on")
	var tick_usec := clock.tick_ms() * USEC_PER_MSEC
	var ready_usec := ready_deadline_usec(scenario_usec, clock)
	print("DEMO sync %d %d" % [clock.estimated_tick_at(scenario_usec), clock.estimated_tick_at(ready_usec)])

	if not await _await_usec(ready_usec - SHOT_BEFORE_LEAD_TICKS * tick_usec):
		return _fail("frames stopped before the first capture")
	if _distance_to_target() <= ATTACK_RANGE:
		return _fail(
			"shot 1 distance %f is inside AttackRange %f; the walk-in claim would be vacuous"
			% [_distance_to_target(), ATTACK_RANGE]
		)
	if not await _capture(1):
		return 1

	var click_usec := clock.next_guard_usec(Time.get_ticks_usec(), click_guard_usec(tick_usec))
	var click_tick := clock.estimated_tick_at(click_usec)
	if not await _await_usec(click_usec):
		return _fail("frames stopped before the attack click")

	if _role == ROLE_ATTACKER:
		if not await _click_target_avatar():
			return 1
	else:
		print("DEMO attackwait %d" % click_tick)

	if not await _wait_until(
		func() -> bool:
			return _hp_of(_victim_id()) == 0,
		KILL_WAIT_MSEC,
	):
		return _fail(
			"victim %d never reached hp 0 (last %d)"
			% [_victim_id(), _hp_of(_victim_id())]
		)

	if _role == ROLE_VICTIM and not _death.visible:
		return _fail("death overlay stayed hidden at hp 0")
	if not await _capture(2):
		return 1

	if _role == ROLE_VICTIM:
		if not await _click_respawn():
			return 1
		if not await _wait_until(
			func() -> bool:
				return _hp_of(_session.own_id()) == MAX_HP and not _death.visible,
			RESTATE_TIMEOUT_MSEC,
		):
			return _fail("respawn never restored HP %d with overlay hidden" % MAX_HP)
		_click_ground_fraction(POST_MOVE_FRACTION)
		print("DEMO postmove %f %f" % [POST_MOVE_FRACTION.x, POST_MOVE_FRACTION.y])
		var post_deadline := Time.get_ticks_msec() + 1200
		while Time.get_ticks_msec() < post_deadline:
			await _tree.process_frame
	else:
		if not await _wait_until(
			func() -> bool:
				return _hp_of(_target_id) == MAX_HP,
			RESTATE_TIMEOUT_MSEC,
		):
			return _fail("target never restored to HP %d after death" % MAX_HP)

	if not await _await_tick(click_tick + HOLD_AFTER_RESPAWN_TICKS):
		return _fail("the clock stalled before the post-respawn capture")
	if not await _capture(3):
		return 1

	print("DEMO done")
	return 0


static func click_guard_usec(tick_usec: int) -> int:
	return tick_usec / 3


static func click_quantum_usec(tick_usec: int) -> int:
	return tick_usec * 8


static func ready_deadline_usec(scenario_usec: int, clock: TickClock) -> int:
	var tick_usec := clock.tick_ms() * USEC_PER_MSEC
	var quantum := click_quantum_usec(tick_usec)
	var quantized: int = ceili(float(scenario_usec) / float(quantum)) * quantum
	return quantized + CLICK_LEAD_TICKS * tick_usec


func _wait_for_scenario() -> int:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.known_ids().size() >= REQUIRED_PLAYERS and _session.own_id() > 0:
			return Time.get_ticks_usec()
		await _tree.process_frame
	return -1


func _relocate_out_of_range() -> bool:
	_click_ground_fraction(RELOCATE_FRACTION)
	print("DEMO relocate %f %f" % [RELOCATE_FRACTION.x, RELOCATE_FRACTION.y])
	if not await _wait_until(
		func() -> bool:
			return _distance_to_target() > MIN_SEPARATION,
		SEPARATE_WAIT_MSEC,
	):
		_fail(
			"relocate never reached separation > %f (last dist %f)"
			% [MIN_SEPARATION, _distance_to_target()]
		)
		return false
	print("DEMO separated %f" % _distance_to_target())
	return true


func _click_target_avatar() -> bool:
	var avatar: PlayerAvatarScript = _session.avatar_for(_target_id)
	if avatar == null:
		_fail("target %d has no avatar to click" % _target_id)
		return false
	var screen_pos: Variant = _screen_position_of_avatar(avatar)
	if screen_pos == null:
		return false
	var screen: Vector2 = screen_pos
	_click_at(screen)
	print(
		"DEMO attackclick %d %d %f %f"
		% [_session.tick_clock().estimated_tick(), _target_id, screen.x, screen.y]
	)
	return true


func _click_respawn() -> bool:
	if _death == null or _death.respawn_button == null:
		_fail("death overlay has no respawn button")
		return false
	var button: Button = _death.respawn_button
	_click_at(button.get_global_rect().get_center())
	print("DEMO respawnclick")
	await _tree.process_frame
	return true


func _victim_id() -> int:
	if _role == ROLE_VICTIM:
		return _session.own_id()
	return _target_id


func _other_id() -> int:
	var own := _session.own_id()
	for id: int in _session.known_ids():
		if id != own:
			return id
	return 0


func _hp_of(id: int) -> int:
	var pair := _session.hit_points_for(id)
	return pair.x


func _distance_to_target() -> float:
	var self_avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	var other: PlayerAvatarScript = _session.avatar_for(_target_id)
	if self_avatar == null or other == null:
		return 0.0
	var a := Vector2(self_avatar.position.x, self_avatar.position.z)
	var b := Vector2(other.position.x, other.position.z)
	return a.distance_to(b)


func _wait_until(predicate: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _tree.process_frame
	return false


func _await_usec(deadline_usec: int) -> bool:
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while Time.get_ticks_usec() < deadline_usec:
		if Time.get_ticks_msec() > backstop:
			return false
		if deadline_usec - Time.get_ticks_usec() > SPIN_USEC:
			await _tree.process_frame
	return true


func _await_tick(target: int) -> bool:
	var clock := _session.tick_clock()
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while clock.estimated_tick() < target:
		if Time.get_ticks_msec() > backstop:
			return false
		await _tree.process_frame
	return true


func _capture(index: int) -> bool:
	for _frame in SCREENSHOT_WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	var path := "%s_%d.png" % [_prefix, index]
	var image := _root.get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("screenshot failed to save to %s: %d" % [path, error])
		return false
	print("DEMO shot %d %s" % [index, path])

	var ids := _session.known_ids()
	print("DEMO players %d %d" % [index, ids.size()])
	for id: int in ids:
		var avatar: PlayerAvatarScript = _session.avatar_for(id)
		if avatar == null:
			continue
		print("DEMO pos %d %d %f %f" % [index, id, avatar.position.x, avatar.position.z])
		var pair := _session.hit_points_for(id)
		if pair.x >= 0:
			print("DEMO hp %d %d %d %d" % [index, id, pair.x, pair.y])

	print("DEMO dist %d %f" % [index, _distance_to_target()])
	if _role == ROLE_VICTIM:
		print("DEMO deathvisible %d %d" % [index, 1 if _death.visible else 0])
		if _hp_hud != null and _hp_hud.visible:
			print("DEMO hphud %d %s" % [index, _hp_hud.text])
	return true


func _screen_position_of_avatar(avatar: PlayerAvatarScript) -> Variant:
	var camera := _root.get_viewport().get_camera_3d()
	if camera == null:
		_fail("the scene has no active camera to project from")
		return null
	var world := avatar.global_position + Vector3(0.0, AVATAR_CLICK_HEIGHT, 0.0)
	if camera.is_position_behind(world):
		_fail("avatar %s is behind the camera; nothing on screen to click" % avatar.name)
		return null
	var screen := camera.unproject_position(world)
	var rect := _root.get_viewport().get_visible_rect()
	if not rect.has_point(screen):
		_fail("avatar %s draws at (%f, %f), outside the viewport %s" % [avatar.name, screen.x, screen.y, rect])
		return null
	print("DEMO avatarscreen %f %f %f %f" % [screen.x, screen.y, rect.size.x, rect.size.y])
	return screen


func _click_ground_fraction(fraction: Vector2) -> void:
	var viewport := _root.get_viewport()
	_click_at(viewport.get_visible_rect().size * fraction)


func _click_at(position: Vector2) -> void:
	var viewport := _root.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		viewport.push_input(event)


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
