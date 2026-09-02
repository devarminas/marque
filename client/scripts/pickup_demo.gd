extends RefCounted

## The M1 milestone, driven from one client: race the other client for the one
## item on the ground, then say what this client saw.
##
## [b]This script judges nothing.[/b] It drives the game and prints greppable
## `DEMO ` lines; `scripts/contested_pickup_demo.ps1` owns every assertion and
## reads them alongside the server's own event log. The one exception is a
## precondition this client can check and the harness cannot — see
## [method _screen_position_of], which refuses to aim a click at an item drawn
## behind the opaque inventory panel — and those exit non-zero after printing
## `DEMO FAIL`.
##
## [b]Why a second demo mode rather than a flag on the first.[/b] `main.gd`'s
## [code]--shots[/code] mode is a two-phase choreography of ground clicks with a
## still-camera pixel control. Nothing in it clicks an item, reports an item
## body, reports an inventory, or synchronises two processes to a single server
## tick, and all four are the M1 claim. Bending it into this shape would have
## cost the M0 milestone its control frames.
##
## [b]Every flag is inert when absent[/b], so the shipped scene is unchanged by
## this file's existence: `main.tscn` reaches none of it without
## [code]--pickup-shots[/code] on the command line.
##
## The choreography, and why each beat is where it is:
##
##   1. Wait until the world holds two players and the one seeded item. Both
##      clients cross that line within a frame of each other — one learns it
##      from `welcome`, the other from the `spawn` that same join produced.
##   2. Read the server's estimated tick at that instant and add
##      [constant CLICK_LEAD_TICKS]. [b]That sum is the whole synchronisation
##      mechanism.[/b] It is a server tick, not wall-clock, so two processes
##      that never speak to each other agree on one moment in the tick loop's
##      own units. Both clients print it, and the harness asserts they picked
##      the same one: a run whose two clients disagreed about *when* is
##      distinguishable from a server that failed to run a contest.
##   3. Capture, click the item, capture again after the contest is resolved.
##   4. Whichever client's inventory came back holding something walks away and
##      drops it. Neither client is told in advance which one it is; the winner
##      identifies itself from the `inventory` the server sent it. The drop is
##      here because the drop's `item_spawn` coordinates are the one thing in
##      this repo that nothing has ever asserted, and a dropper standing
##      somewhere it deliberately walked to is the only way to tell a truthful
##      coordinate from a zeroed one.
##   5. Capture a third time: the item is back on the ground, in both worlds.
##
## Typed by [code]preload[/code] rather than by global [code]class_name[/code],
## per NOTES.md, "Godot authoring traps".

const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")

## Frames to let the renderer settle before capturing. The first frame has no
## shadows and no sky resolved yet. Same figure as `main.gd`'s; it is a property
## of the renderer, not of either choreography.
const SCREENSHOT_WARMUP_FRAMES := 15

## How many players and how many ground items the world must hold before the
## run starts. The milestone is two clients contesting one item, so any other
## count is a scenario this script was not asked to drive.
const REQUIRED_PLAYERS := 2
const REQUIRED_ITEMS := 1

## How long to wait for that, in milliseconds. Generous: it covers the other
## process starting Godot, importing, and connecting.
const JOIN_TIMEOUT_MSEC := 20000

## Server ticks between the moment both clients can see the whole scenario and
## the moment they click the item. Long enough for the slower of two Godot
## processes to have settled its camera and drawn a frame worth capturing.
const CLICK_LEAD_TICKS := 20

## Server ticks before the click at which the "before" frame is captured. The
## capture itself costs [constant SCREENSHOT_WARMUP_FRAMES] rendered frames,
## which is under two ticks on an idle machine; this leaves room for that plus
## slack, so the click is never issued while a capture is still running.
const SHOT_BEFORE_LEAD_TICKS := 6

## Server ticks from the click to the "after" frame. The seeded item is a walk
## of roughly sixteen ticks from the origin and resolution happens on arrival,
## so this is the contest plus half again.
const SHOT_RESOLVED_OFFSET_TICKS := 26

## Server ticks from the click to the winner's walk away from the item.
const WALK_AWAY_OFFSET_TICKS := 30

## Server ticks from the click by which that walk must have finished. The winner
## drops as soon as its own body is idle; this is the backstop, and blowing
## through it is a failure rather than a reason to drop mid-walk — a drop while
## walking lands the item under the walker, which is correct behaviour and would
## make this run's coordinate assertion measure the wrong thing.
const WALK_AWAY_DEADLINE_TICKS := 68

## Server ticks from the click to the frame that shows the dropped item.
const SHOT_DROPPED_OFFSET_TICKS := 76

## Server ticks from the click to this client releasing its connection.
##
## The two clients keep time independently and drift by a frame or two, and a
## client that quits early despawns a body out of the other's last frame.
const HOLD_UNTIL_OFFSET_TICKS := 88

## Wall-clock backstop on any tick wait, in milliseconds. A clock that stopped
## advancing would otherwise spin here forever and the run would be killed by
## the harness's timeout with nothing said about why.
const TICK_WAIT_BACKSTOP_MSEC := 60000

var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _panel: InventoryPanelScript
var _prefix: String
var _drop_click: Vector2


## Runs the whole choreography. Returns the process exit code.
##
## [param drop_click] is a viewport fraction for the ground click the winner
## makes before dropping. It must resolve to ground rather than to the panel,
## and it must not be where the winner already stands: the drop's coordinates
## are asserted against where the dropper walked to, so a destination equal to
## the pickup point would prove nothing about them.
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

	if not await _wait_for_scenario():
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
	var sync_tick := clock.estimated_tick()
	var click_tick := sync_tick + CLICK_LEAD_TICKS
	print("DEMO sync %d %d" % [sync_tick, click_tick])

	if not await _await_tick(click_tick - SHOT_BEFORE_LEAD_TICKS):
		return _fail("the clock stalled before the first capture")
	if not await _capture(1):
		return _fail("capture 1 failed")

	if not await _await_tick(click_tick):
		return _fail("the clock stalled before the click")
	# Explicitly typed rather than inferred: the source is a Variant, because a
	# refusal has to be distinguishable from a coordinate and no Vector2 is
	# reserved for "no". NOTES.md, "Godot authoring traps": an inferred Variant
	# is a warning, and warnings are errors here.
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

	# Nobody was told who won. This client reads it off the inventory the server
	# sent it, which is the only place the answer exists on this side.
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
##
## Every step is a real click through the real widgets, so the drop travels the
## whole path a player's drop travels: button, panel, session, socket.
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
## Waiting on both together rather than on the players alone is what keeps the
## synchronisation honest. A client that started its countdown on the second
## player and had not yet been told about the item would click at the right
## moment at nothing at all.
func _wait_for_scenario() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if (_session.known_ids().size() >= REQUIRED_PLAYERS
				and _session.known_item_ids().size() >= REQUIRED_ITEMS):
			return true
		await _tree.process_frame
	return false


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
## [b]Both halves, in that order, and the first one is the load-bearing half.[/b]
## A body whose new path has not arrived yet is still holding the end of its
## previous one, and [method PlayerAvatar.is_idle_at_tick] answers true for it.
## Waiting only for idle would therefore return immediately, on the previous
## walk, and the drop that followed would land the item wherever the pickup left
## the player. That is a coordinate this run cannot tell apart from a truthful
## one, which is the whole thing this unit exists to close.
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
##
## The counts are printed unconditionally, ahead of the lines they count. A shot
## with no `DEMO item` lines is otherwise ambiguous between "the world holds no
## items", which is exactly what the middle frame has to show, and "the loop
## that prints them broke".
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
## [b]Two refusals, and neither is hypothetical.[/b] A body behind the camera
## unprojects to a point in front of it, so the depth test comes first. And the
## inventory panel is opaque (M1k): a click that lands on it stops there, so a
## run whose item happens to draw under the panel would fail on the server
## saying no `pickup` ever arrived — a true statement about a scenario that
## never happened. Saying so here is the difference between a diagnosed run and
## an hour of debugging the harness.
##
## The refusal predates the panel being opaque and did not change with it. Only
## the ending changed: the click used to walk this player instead of picking
## anything up, and now it does nothing at all. Either way the item was never
## clicked, so either way this is not a run worth reporting on.
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


## Pushes a real left press and release at a viewport pixel position, so the
## click travels the whole path a player's click travels.
##
## The release is not decoration. The world's picker acts on the press, but an
## inventory slot is a [Button] and a Button fires on release; one helper that
## sends both is what lets the same call drive a click on the ground, a click on
## an item, and a click on a slot.
func _click_at(position: Vector2) -> void:
	var viewport := _root.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		viewport.push_input(event)


## Reports a failure the way the harness reads it, and returns the exit code.
##
## Loud on both streams: `DEMO FAIL` on stdout because that is the stream the
## harness parses, and [method @GlobalScope.printerr] because a run read by a
## human is read from its stderr first.
func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1
