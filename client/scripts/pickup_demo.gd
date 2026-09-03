extends RefCounted

## The M1 milestone, driven from one client: race the other client for the one
## item on the ground, then say what this client saw.
##
## Prints greppable `DEMO ` lines and asserts almost nothing;
## `scripts/contested_pickup_demo.ps1` owns the assertions and reads these
## alongside the server's event log.

const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")

const SCREENSHOT_WARMUP_FRAMES := 15

const REQUIRED_PLAYERS := 2
const REQUIRED_ITEMS := 1

const JOIN_TIMEOUT_MSEC := 20000

const USEC_PER_MSEC := 1000

## How long after the shared moment the two clients click, in server ticks.
##
## [b]The moment is shared. A tick number naming it is not.[/b] Both clients
## learn the roster reached two players out of one [code]addPlayer[/code] on the
## server. The later joiner learns it from its own [code]welcome[/code] and the
## earlier one from the [code]spawn[/code] enqueued in the same step, so
## counting microseconds from there has the two of them click at one instant.
##
## Waiting for a tick number instead throws that instant away. The server
## composes [code]welcome[/code] on its event arm and not inside
## [code]step[/code], so each client anchors somewhere inside a tick and its own
## tick boundaries sit that far late, by an amount it cannot observe and that
## differs per client ([code]tick_clock.gd[/code], [code]estimated_tick[/code]).
## Two clients waiting for tick N clicked up to a whole tick apart, and the
## server assigned their two walks on different ticks on 8 of M1j's 21 idle
## runs, which [code]scripts/contested_pickup_demo.ps1[/code] rightly refuses as
## a sequence rather than a contest.
const CLICK_LEAD_TICKS := 20

## Offsets around the click. They must stay in this order. The lead-in counts
## back from the click moment; the rest run on from the tick the click landed
## on, where a tick either way costs nothing.
const SHOT_BEFORE_LEAD_TICKS := 6
const SHOT_RESOLVED_OFFSET_TICKS := 26
const WALK_AWAY_OFFSET_TICKS := 30
const WALK_AWAY_DEADLINE_TICKS := 68
const SHOT_DROPPED_OFFSET_TICKS := 76
const HOLD_UNTIL_OFFSET_TICKS := 88

const TICK_WAIT_BACKSTOP_MSEC := 60000

var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _panel: InventoryPanelScript
var _prefix: String
var _drop_click: Vector2


## Runs the whole choreography. Returns the process exit code.
##
## [param drop_click] is a viewport fraction. It must resolve to ground, and it
## must not be where the winner already stands.
func run(
	root: Node,
	session: SessionScript,
	panel: InventoryPanelScript,
	prefix: String,
	drop_click: Vector2,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_panel = panel
	_prefix = prefix
	_drop_click = drop_click

	var scenario_usec := await _wait_for_scenario()
	if scenario_usec < 0:
		return _fail(
			"fewer than %d player(s) or %d item(s) after %dms"
			% [REQUIRED_PLAYERS, REQUIRED_ITEMS, JOIN_TIMEOUT_MSEC]
		)
	print("DEMO joined %d" % _session.own_id())

	var item_id: int = _session.known_item_ids()[0]
	var item := _session.item_for(item_id)
	print("DEMO seeditem %d %s %f %f" % [item_id, item.kind, item.position.x, item.position.z])

	var clock := _session.tick_clock()
	if not clock.is_anchored():
		return _fail("the tick clock is not anchored; there is no shared moment to click on")
	var tick_usec := clock.tick_ms() * USEC_PER_MSEC
	var click_usec := scenario_usec + CLICK_LEAD_TICKS * tick_usec
	var sync_tick := clock.estimated_tick_at(scenario_usec)
	var click_tick := clock.estimated_tick_at(click_usec)
	print("DEMO sync %d %d" % [sync_tick, click_tick])

	if not await _await_usec(click_usec - SHOT_BEFORE_LEAD_TICKS * tick_usec):
		return _fail("frames stopped before the first capture")
	if not await _capture(1):
		return _fail("capture 1 failed")

	if not await _await_usec(click_usec):
		return _fail("frames stopped before the click")
	var picked: Variant = _screen_position_of(item)
	if picked == null:
		return 1
	var screen: Vector2 = picked
	print("DEMO pickupclick %d %d %f %f" % [clock.estimated_tick(), item_id, screen.x, screen.y])
	_click_at(screen)

	if not await _await_tick(click_tick + SHOT_RESOLVED_OFFSET_TICKS):
		return _fail("the clock stalled before the second capture")
	if not await _capture(2):
		return _fail("capture 2 failed")

	var won := _panel.occupied_slot_count() > 0
	print("DEMO outcome %d" % (1 if won else 0))
	if won and not await _walk_away_and_drop(click_tick):
		return 1

	if not await _await_tick(click_tick + SHOT_DROPPED_OFFSET_TICKS):
		return _fail("the clock stalled before the third capture")
	if not await _capture(3):
		return _fail("capture 3 failed")

	if not await _await_tick(click_tick + HOLD_UNTIL_OFFSET_TICKS):
		return _fail("the clock stalled during the hold")
	print("DEMO done")
	return 0


## The winner's half: walk somewhere it chose, wait to actually arrive, then
## drop by clicking its own occupied slot.
func _walk_away_and_drop(click_tick: int) -> bool:
	if not await _await_tick(click_tick + WALK_AWAY_OFFSET_TICKS):
		_fail("the clock stalled before the walk away")
		return false

	var viewport := _root.get_viewport()
	var target := viewport.get_visible_rect().size * _drop_click
	if _panel.visible and _panel.get_global_rect().has_point(target):
		_fail(
			"the drop-walk click at (%f, %f) lands on the inventory panel %s"
			% [target.x, target.y, _panel.get_global_rect()]
		)
		return false
	print("DEMO groundclick %d %f %f" % [_session.tick_clock().estimated_tick(), target.x, target.y])
	_click_at(target)

	if not await _await_arrival(click_tick + WALK_AWAY_DEADLINE_TICKS):
		_fail(
			"this client's own body was still walking at tick %d; dropping now would land the "
			% (click_tick + WALK_AWAY_DEADLINE_TICKS)
			+ "item under a walker rather than at a destination it reached"
		)
		return false

	var slot := _first_occupied_slot()
	if slot < 0:
		_fail("this client won the item but has no occupied slot to drop from")
		return false
	var widget := _panel.slot_at(slot)
	if widget == null:
		_fail("the panel draws no widget for slot %d" % slot)
		return false
	print("DEMO dropclick %d %d" % [_session.tick_clock().estimated_tick(), slot])
	_click_at(widget.get_global_rect().get_center())
	return true


## Waits until the world holds the whole scenario: both players and the item.
##
## Returns the monotonic microsecond at which this client saw it, or -1 if it
## never did. That instant is the two clients' one shared moment, and everything
## up to the click is measured from it; see [constant CLICK_LEAD_TICKS].
func _wait_for_scenario() -> int:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if (_session.known_ids().size() >= REQUIRED_PLAYERS
				and _session.known_item_ids().size() >= REQUIRED_ITEMS):
			return Time.get_ticks_usec()
		await _tree.process_frame
	return -1


## Waits until the monotonic clock reaches [param deadline_usec]. False means
## frames stopped arriving, which is the only way this can fail, because
## monotonic time itself cannot stall.
func _await_usec(deadline_usec: int) -> bool:
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while Time.get_ticks_usec() < deadline_usec:
		if Time.get_ticks_msec() > backstop:
			return false
		await _tree.process_frame
	return true


## Waits until the estimated server tick reaches [param target]. False means the
## clock stopped advancing and the caller must fail rather than carry on.
func _await_tick(target: int) -> bool:
	var clock := _session.tick_clock()
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while clock.estimated_tick() < target:
		if Time.get_ticks_msec() > backstop:
			return false
		await _tree.process_frame
	return true


## Waits for this client's own body to start the walk it was just told to make
## and then finish it, or until [param deadline_tick].
##
## The first loop is load-bearing: a body whose new path has not arrived is
## still idle at the end of its previous one.
func _await_arrival(deadline_tick: int) -> bool:
	var clock := _session.tick_clock()
	var avatar := _session.avatar_for(_session.own_id())
	if avatar == null:
		return false
	while avatar.is_idle_at_tick(clock.estimated_tick()):
		if clock.estimated_tick() >= deadline_tick:
			return false
		await _tree.process_frame
	while not avatar.is_idle_at_tick(clock.estimated_tick()):
		if clock.estimated_tick() >= deadline_tick:
			return false
		await _tree.process_frame
	return true


## Captures one frame and reports everything in it that the claim depends on:
## every player body, every item body, and this client's inventory.
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

	var item_ids := _session.known_item_ids()
	print("DEMO items %d %d" % [index, item_ids.size()])
	for id: int in item_ids:
		var body: GroundItemScript = _session.item_for(id)
		if body == null:
			continue
		print("DEMO item %d %d %s %f %f" % [index, id, body.kind, body.position.x, body.position.z])

	print("DEMO inv %d %d %d" % [index, _panel.occupied_slot_count(), _panel.slot_count()])
	for slot in _panel.slot_count():
		var kind := _panel.kind_in_slot(slot)
		if not kind.is_empty():
			print("DEMO invslot %d %d %s" % [index, slot, kind])
	return true


## Where on screen [param body] is drawn, or null when it is somewhere this
## script refuses to click.
##
## The depth test comes first: a body behind the camera unprojects to a point in
## front of it.
func _screen_position_of(body: Node3D) -> Variant:
	var camera := _root.get_viewport().get_camera_3d()
	if camera == null:
		_fail("the scene has no active camera to project from")
		return null
	if camera.is_position_behind(body.global_position):
		_fail("item %s is behind the camera; nothing on screen to click" % body.name)
		return null

	var screen := camera.unproject_position(body.global_position)
	var rect := _root.get_viewport().get_visible_rect()
	if not rect.has_point(screen):
		_fail("item %s draws at (%f, %f), outside the viewport %s" % [body.name, screen.x, screen.y, rect])
		return null
	if _panel.visible and _panel.get_global_rect().has_point(screen):
		_fail(
			"item %s draws at (%f, %f), under the inventory panel %s, which is opaque "
			% [body.name, screen.x, screen.y, _panel.get_global_rect()]
			+ "(M1k): the click would stop at the panel and never reach the item"
		)
		return null
	print("DEMO itemscreen %f %f %f %f" % [screen.x, screen.y, rect.size.x, rect.size.y])
	return screen


## The lowest occupied inventory slot, or -1 when the inventory is empty.
func _first_occupied_slot() -> int:
	for slot in _panel.slot_count():
		if not _panel.kind_in_slot(slot).is_empty():
			return slot
	return -1


## Pushes a real left press and release at a viewport pixel position.
##
## Both, because the picker acts on the press but a slot is a [Button] and fires
## on release.
func _click_at(position: Vector2) -> void:
	var viewport := _root.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		viewport.push_input(event)


## Reports a failure and returns the exit code. Both streams: stdout is what the
## harness parses, stderr is what a human reads first.
func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
