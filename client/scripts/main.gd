extends Node3D

## Scene root for [code]main.tscn[/code].
##
## It owns one behaviour: the game drives and screenshots itself on request.
## Everything else in this scene is authored content and needs no script
## (CLAUDE.md).
##
## Anything genuinely visual cannot be checked headless, so the visual check is a
## separate windowed run that captures its own frame. The desktop is not
## automated (NOTES.md, "Headless testing"):
##
## [codeblock]
## godot --path client -- --screenshot
## [/codeblock]
##
## [b]The milestone check needs two of those at once[/b], each watching the
## other, so the same script also drives a scripted client:
##
## [codeblock]
## godot --path client -- --server ws://127.0.0.1:8080/ws \
##     --shots C:/tmp/marque/a --click 0.30,0.72 --phase 1
## [/codeblock]
##
## Which waits until it can see another player, then runs two phases. In its own
## phase it clicks the ground and walks; in the other phase it stands still and
## watches. It captures a frame near the start and near the end of each phase,
## printing a greppable line per capture and per body it drew.
## `scripts/two_client_demo.ps1` runs two of them on opposite phases, so each
## client is the walker once and the watcher once.
##
## The flags do nothing when they are absent, so the shipped scene is unchanged
## by their existence. [method OS.get_cmdline_user_args] is everything after the
## engine's own `--`, so none of them can collide with a Godot option.

const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const PickupDemoScript := preload("res://scripts/pickup_demo.gd")

## One capture to [constant SCREENSHOT_PATH], then quit. M0c's visual check.
const SCREENSHOT_FLAG := "--screenshot"
const SCREENSHOT_PATH := "user://shot.png"

## A file of scripted server frames applied before anything else, one JSON
## object per line, as `--feed C:/tmp/world.ndjson`. **M1.**
##
## The visual check for anything a client only learns about from the wire cannot
## wait for the server that sends it. Ground items are drawn by `session.gd` in
## response to frames, so [constant SCREENSHOT_FLAG] on its own captures a world
## with no items in it and proves nothing about them.
##
## [b]Not a second protocol and not a fixture format.[/b] Every line goes through
## the same [code]ingest_text_frame[/code] the socket goes through, so a frame
## that would be rejected on the wire is rejected here too, and the picture this
## produces is the picture a conforming server would produce.
const FEED_FLAG := "--feed"

## Two captures around a scripted walk, written to `<prefix>_1.png` and
## `<prefix>_2.png`.
##
## The prefix is an absolute host path rather than a [code]user://[/code] one on
## purpose: two Godot processes share one [code]user://[/code] directory and
## would overwrite each other's frames (NOTES.md, "Headless testing").
const SHOTS_FLAG := "--shots"

## Click the ground at a viewport fraction, as `--click 0.30,0.72`.
const CLICK_FLAG := "--click"

## Which of the demo's phases this client walks in, as `--phase 1`. Absent or 0
## means it never walks.
##
## The phases exist so that the two clients take turns. While one walks the
## other stands still, and a client that stands still has a camera that stands
## still, which is what makes its two frames comparable pixel for pixel. Both
## clients walk over the run, so both directions of "each sees the other walk"
## are captured, and each direction gets its still-camera window.
const PHASE_FLAG := "--phase"

## Three captures around a contested pickup, written to `<prefix>_1.png` through
## `<prefix>_3.png`. **M1e**, the milestone.
##
## A mode of its own rather than a phase inside [constant SHOTS_FLAG]. That one
## is a choreography of ground clicks whose whole point is that exactly one
## player moves per capture window, so that a still camera can be the pixel
## control. This is the opposite scenario by construction: two players click the
## same item on the same server tick, and there is no still camera anywhere in
## it. `pickup_demo.gd` drives it and documents each beat.
##
## The prefix is an absolute host path, for [constant SHOTS_FLAG]'s reason.
const PICKUP_SHOTS_FLAG := "--pickup-shots"

## Where the winner of that contest clicks the ground before dropping the item,
## as a viewport fraction: `--drop-click 0.30,0.62`. **M1e.**
##
## The walk is not decoration. A drop lands the item at the dropper's position,
## and telling a truthful coordinate from a zeroed one needs a dropper standing
## somewhere that is neither the origin nor where the item was picked up.
const DROP_CLICK_FLAG := "--drop-click"

## How many phases the demo runs. One per client.
const DEMO_PHASES := 2

## Frames to let the renderer settle before capturing. The first frame has no
## shadows and no sky resolved yet, so a capture there proves nothing.
const SCREENSHOT_WARMUP_FRAMES := 15

## How many players have to be in the world before the demo starts capturing.
## The milestone is two clients seeing each other, so one is not enough.
const DEMO_MIN_PLAYERS := 2

## How long the demo waits for that, in milliseconds. Generous: it covers the
## other process starting Godot, importing, and connecting.
const DEMO_JOIN_TIMEOUT_MSEC := 20000

## Milliseconds between a phase's click and that phase's first capture.
##
## The capture is deliberately after the click rather than before it. Everyone
## spawns at the origin in M0, so a frame taken before anybody has walked shows
## two capsules standing inside each other, which is a picture of one capsule.
## Letting the walker get clear first is what makes every frame show two bodies.
const DEMO_SETTLE_MSEC := 400

## Milliseconds between a phase's two captures. At the server's 3.0 units per
## second this is several world units of travel, which is a displacement nobody
## has to squint at.
const DEMO_WALK_MSEC := 1400

## Milliseconds between one phase's last capture and the next phase's click.
##
## Long enough that the previous phase's walker has stopped, so that exactly one
## player is moving in any capture window — and then longer again, because the
## camera rig chases its target with exponential damping and keeps producing
## distinct positions for a while after the target stops. A frame captured while
## the rig is still converging is not a still-camera frame, and the pixel
## control in `scripts/two_client_demo.ps1` measured exactly that at 300ms.
const DEMO_PHASE_GAP_MSEC := 1200

## Milliseconds to stay connected after the last capture.
##
## The two clients keep time independently, off an event they both observe, and
## they drift by a few hundred milliseconds over four captures because their
## windows do not render at exactly the same rate. Without this hold the client
## that finishes first quits, the server despawns it, and the other client's
## last frame has one body in it instead of two. Generous: it costs nothing and
## the failure it prevents is the whole point of the run.
const DEMO_HOLD_MSEC := 2000


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	# Before either capture path, and before any socket could deliver a frame:
	# a scripted world is only a starting state, and a live server's frames
	# arrive on top of it exactly as they would on top of an empty one.
	_feed_scripted_frames(args)
	if PICKUP_SHOTS_FLAG in args:
		await _run_pickup_demo(args)
		return
	if SHOTS_FLAG in args:
		await _run_demo(args)
		return
	if SCREENSHOT_FLAG in args:
		await _capture_and_quit()


## Applies [constant FEED_FLAG]'s file, one JSON frame per line, and returns how
## many frames it fed. Zero when the flag is absent, which is not a failure.
##
## A blank line is skipped so the file can be laid out for a human to read. A
## frame that will not decode logs from inside `net_client.gd` and is dropped
## there, which is the behaviour under test rather than a case to handle here.
## So the count is frames [i]offered[/i], and the world line printed after it is
## what says whether they landed.
##
## [b]It takes an argument list rather than a path[/b] so that a test can drive
## the flag parsing, the file reading, and the decoding in one call.
## [constant FEED_FLAG] is otherwise reachable only by launching a process, and
## a screenshot flag that nothing automated touches is a flag which breaks
## silently between screenshots. **M1d**, closing M1c's gap; `test_interaction.gd`
## calls this with a synthetic argument list and asserts on both numbers.
func _feed_scripted_frames(args: Array) -> int:
	var path := _argument_after(args, FEED_FLAG)
	if path.is_empty():
		return 0

	var net := get_node_or_null("Session/Net") as NetClientScript
	if net == null:
		push_error("main.tscn has no Session/Net node to feed")
		get_tree().quit(1)
		return 0

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error(
			"%s could not open %s: %d" % [FEED_FLAG, path, FileAccess.get_open_error()]
		)
		get_tree().quit(1)
		return 0

	var count := 0
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		net.ingest_text_frame(line)
		count += 1
	print("main: fed %d scripted frame(s) from %s" % [count, path])
	_print_world_contents()
	return count


## What the fed frames actually built. Printed rather than judged: this script
## drives the game and reports, and the line is what makes a screenshot run say
## out loud whether the world it is about to capture has anything in it.
func _print_world_contents() -> void:
	var session := get_node_or_null("Session") as SessionScript
	if session == null:
		push_error("main.tscn has no Session node to report")
		return
	var panel := get_node_or_null("UI/InventoryPanel") as InventoryPanelScript
	var slots := -1 if panel == null else panel.slot_count()
	var carried := -1 if panel == null else panel.occupied_slot_count()
	print(
		"main: world holds %d player body(s), %d item body(s), %d/%d inventory slot(s) filled"
		% [session.known_ids().size(), session.known_item_ids().size(), carried, slots]
	)


## The contested-pickup check, from this client's side. **M1e.**
##
## Parses the flags here, where every other flag is parsed, and hands typed
## values to `pickup_demo.gd`, which owns the choreography. The exit code is
## that script's: it is the only thing in this path that knows whether the run
## reached its own preconditions.
func _run_pickup_demo(args: Array) -> void:
	var prefix := _argument_after(args, PICKUP_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % PICKUP_SHOTS_FLAG)
		get_tree().quit(1)
		return
	# Refused rather than defaulted. [method _parse_fraction] centres a fraction
	# it cannot read, which keeps the M0 demo producing comparable frames; here
	# the fraction decides where an item is dropped and a silent centre would
	# make this run measure a destination nobody asked for.
	var drop_click := _argument_after(args, DROP_CLICK_FLAG)
	if drop_click.split(",").size() != 2:
		push_error("%s needs a viewport fraction after it, like 0.30,0.62" % DROP_CLICK_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var panel := get_node_or_null("UI/InventoryPanel") as InventoryPanelScript
	if session == null or panel == null:
		push_error("main.tscn is missing the Session or UI/InventoryPanel node to drive")
		get_tree().quit(1)
		return

	var demo := PickupDemoScript.new()
	var code: int = await demo.run(self, session, panel, prefix, _parse_fraction(drop_click))
	get_tree().quit(code)


## The two-client visual check, from this client's side.
##
## Every line it prints is meant to be grepped by
## `scripts/two_client_demo.ps1`, which owns the assertions. This side reports
## what it drew and where; it does not judge it.
func _run_demo(args: Array) -> void:
	var prefix := _argument_after(args, SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % SHOTS_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	if session == null:
		push_error("main.tscn has no Session node to drive")
		get_tree().quit(1)
		return

	if not await _wait_for_players(session):
		printerr("DEMO TIMEOUT: fewer than %d players after %dms" % [
			DEMO_MIN_PLAYERS, DEMO_JOIN_TIMEOUT_MSEC
		])
		get_tree().quit(1)
		return
	print("DEMO joined %d" % session.own_id())

	# Both clients cross the "somebody else is here" line within a frame or two
	# of each other — one learns it from `welcome`, the other from the `spawn`
	# that same join produced — so timing every phase off that line keeps two
	# separate processes in step without either knowing about the other's
	# schedule, and without a phase message existing on the wire.
	var click := _argument_after(args, CLICK_FLAG)
	var my_phase := _argument_after(args, PHASE_FLAG).to_int()
	var shot := 0

	for phase in range(1, DEMO_PHASES + 1):
		if phase > 1:
			await _wait_msec(DEMO_PHASE_GAP_MSEC)
		if phase == my_phase and not click.is_empty():
			_click_ground_at(_parse_fraction(click))

		await _wait_msec(DEMO_SETTLE_MSEC)
		shot += 1
		if not await _capture(session, prefix, shot):
			get_tree().quit(1)
			return

		await _wait_msec(DEMO_WALK_MSEC)
		shot += 1
		if not await _capture(session, prefix, shot):
			get_tree().quit(1)
			return

	# Held connected, not idle: the other client may still be composing its last
	# frame, and this one leaving would empty a body out of it.
	await _wait_msec(DEMO_HOLD_MSEC)
	print("DEMO done")
	get_tree().quit(0)


## Waits until the world has somebody else in it. Wall-clock is legitimate here:
## this is scripting, not game logic, and nothing derives a position from it.
func _wait_for_players(session: SessionScript) -> bool:
	var deadline := Time.get_ticks_msec() + DEMO_JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if session.known_ids().size() >= DEMO_MIN_PLAYERS:
			return true
		await get_tree().process_frame
	return false


## Captures one frame and reports every body in it.
##
## The positions are read out of the same avatars the renderer just drew, so the
## printed line and the PNG describe one moment rather than two.
func _capture(session: SessionScript, prefix: String, index: int) -> bool:
	for _frame in SCREENSHOT_WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	var path := "%s_%d.png" % [prefix, index]
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("screenshot failed to save to %s: %d" % [path, error])
		return false

	print("DEMO shot %d %s" % [index, path])
	for id: int in session.known_ids():
		var avatar: PlayerAvatarScript = session.avatar_for(id)
		if avatar == null:
			continue
		print("DEMO pos %d %d %f %f" % [index, id, avatar.position.x, avatar.position.z])
	return true


## Pushes a real left click at a fraction of the viewport, so the click travels
## the whole path a player's click travels: picker, session, socket.
func _click_ground_at(fraction: Vector2) -> void:
	var viewport := get_viewport()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = viewport.get_visible_rect().size * fraction
	viewport.push_input(press)
	print("DEMO clicked %f %f" % [press.position.x, press.position.y])


func _wait_msec(duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _capture_and_quit() -> void:
	for _frame in SCREENSHOT_WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(SCREENSHOT_PATH)
	if error != OK:
		push_error("screenshot failed to save to %s: %d" % [SCREENSHOT_PATH, error])
		get_tree().quit(1)
		return

	print("screenshot: ", ProjectSettings.globalize_path(SCREENSHOT_PATH))
	get_tree().quit(0)


## The argument after [param flag], or "" when the flag is absent or last.
static func _argument_after(args: Array, flag: String) -> String:
	var index := args.find(flag)
	if index == -1 or index + 1 >= args.size():
		return ""
	return args[index + 1]


## Parses "0.30,0.72" into a viewport fraction. Anything unparseable centres the
## click rather than aborting the run: a demo that lost its click position still
## produces two comparable frames, and the print above says where it landed.
static func _parse_fraction(text: String) -> Vector2:
	var parts := text.split(",")
	if parts.size() != 2 or not parts[0].is_valid_float() or not parts[1].is_valid_float():
		push_error("%s wants two floats like 0.30,0.72, got %s" % [CLICK_FLAG, text])
		return Vector2(0.5, 0.5)
	return Vector2(float(parts[0]), float(parts[1]))
