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
##     --shots C:/tmp/marque/a --click 0.30,0.72
## [/codeblock]
##
## Which waits until it can see another player, captures a frame, clicks the
## ground, waits, and captures a second frame, printing a greppable line per
## capture and per body it drew. `scripts/two_client_demo.ps1` runs two of them.
##
## The flags do nothing when they are absent, so the shipped scene is unchanged
## by their existence. [method OS.get_cmdline_user_args] is everything after the
## engine's own `--`, so none of them can collide with a Godot option.

const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")

## One capture to [constant SCREENSHOT_PATH], then quit. M0c's visual check.
const SCREENSHOT_FLAG := "--screenshot"
const SCREENSHOT_PATH := "user://shot.png"

## Two captures around a scripted walk, written to `<prefix>_1.png` and
## `<prefix>_2.png`.
##
## The prefix is an absolute host path rather than a [code]user://[/code] one on
## purpose: two Godot processes share one [code]user://[/code] directory and
## would overwrite each other's frames (NOTES.md, "Headless testing").
const SHOTS_FLAG := "--shots"

## Click the ground at a viewport fraction, as `--click 0.30,0.72`.
const CLICK_FLAG := "--click"

## Frames to let the renderer settle before capturing. The first frame has no
## shadows and no sky resolved yet, so a capture there proves nothing.
const SCREENSHOT_WARMUP_FRAMES := 15

## How many players have to be in the world before the demo starts capturing.
## The milestone is two clients seeing each other, so one is not enough.
const DEMO_MIN_PLAYERS := 2

## How long the demo waits for that, in milliseconds. Generous: it covers the
## other process starting Godot, importing, and connecting.
const DEMO_JOIN_TIMEOUT_MSEC := 20000

## Milliseconds between the click and the first capture.
##
## The capture is deliberately after the click rather than before it. Everyone
## spawns at the origin in M0, so a frame taken before anybody has walked shows
## two capsules standing inside each other, which is a picture of one capsule.
## Letting the walker get clear first is what makes both frames show two bodies.
const DEMO_SETTLE_MSEC := 600

## Milliseconds between the two captures. At the server's 3.0 units per second
## this is several world units of travel, which is a displacement nobody has to
## squint at.
const DEMO_WALK_MSEC := 1200


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if SHOTS_FLAG in args:
		await _run_demo(args)
		return
	if SCREENSHOT_FLAG in args:
		await _capture_and_quit()


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
	# that same join produced — so timing both captures off that line keeps two
	# separate processes' frames comparable without either knowing about the
	# other's schedule.
	var click := _argument_after(args, CLICK_FLAG)
	if not click.is_empty():
		_click_ground_at(_parse_fraction(click))

	await _wait_msec(DEMO_SETTLE_MSEC)
	if not await _capture(session, prefix, 1):
		get_tree().quit(1)
		return

	await _wait_msec(DEMO_WALK_MSEC)
	if not await _capture(session, prefix, 2):
		get_tree().quit(1)
		return

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
