extends Node3D

## Scene root for [code]main.tscn[/code].
##
## It owns one behaviour: the game screenshots itself on request. Everything
## else in this scene is authored content and needs no script (CLAUDE.md).
##
## Anything genuinely visual cannot be checked headless, so the visual check is
## a separate windowed run that captures its own frame. The desktop is not
## automated (NOTES.md, "Headless testing"):
##
## [codeblock]
## godot --path client -- --screenshot
## [/codeblock]

const SCREENSHOT_FLAG := "--screenshot"
const SCREENSHOT_PATH := "user://shot.png"
## Frames to let the renderer settle before capturing. The first frame has no
## shadows and no sky resolved yet, so a capture there proves nothing.
const SCREENSHOT_WARMUP_FRAMES := 15


func _ready() -> void:
	if SCREENSHOT_FLAG not in OS.get_cmdline_user_args():
		return
	await _capture_and_quit()


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
