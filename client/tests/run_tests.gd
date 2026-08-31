extends SceneTree

## Headless entry point, per NOTES.md, "Headless testing":
##
## [codeblock]
## godot --headless --path client --script res://tests/run_tests.gd --quit-after 900
## [/codeblock]
##
## The assertions live in test scenes rather than here, because they need a real
## scene tree: a stepped physics space, a camera in a viewport, the authored
## ground body from [code]main.tscn[/code], and a node that gets a frame so a
## socket can be polled. Loading scenes rather than assembling them keeps this
## unit free of [method Node.add_child].
##
## [b]The suite contract.[/b] Suites in [constant SUITES] run in order.
##
## - Every suite but the last reports through two properties: [code]finished[/code]
##   flips to true when it is done, [code]passed[/code] says whether it held.
##   Polling them rather than connecting a signal removes the race between a
##   suite that finishes early and a runner that has not attached yet.
## - Such a suite must never quit the tree, and must not report inside
##   [method Node._ready]; it needs at least one frame.
## - The last suite owns the exit code and quits the tree itself.
##
## This runner owns the ways a test run can pass by accident:
##
## 1. A scene loads but its script does not compile. Godot attaches no script,
##    nothing asserts, nothing quits, and [code]--quit-after[/code] exits 0.
## 2. The tests hang. Same ending, same false pass.
## 3. [code]--quit-after[/code] fires before the tests finish. The engine quits
##    normally and the process exits 0 having proven nothing.
## 4. A suite is registered that reports nothing, so the run walks past it.
##
## 1, 2 and 4 are watched below. 3 is covered twice: [constant WATCHDOG_FRAMES]
## is below the documented [code]--quit-after[/code], because a bound above it
## can never fire, and [method _finalize] fails any run that ends without having
## reached the last suite, whatever ended it.
##
## [b]Known gap.[/b] [method _finalize] cannot tell a last suite that quit(0)
## after passing from a last suite that [code]--quit-after[/code] cut short,
## because [code]OS.exit_code[/code] is not exposed in Godot 4.7 and only an
## explicit [method SceneTree.quit] can set the code. The window is the handful
## of frames the last suite runs for, and the frame watchdog covers it under the
## documented command. It closes for good when the last suite reports through
## [code]finished[/code]/[code]passed[/code] like every other one and this runner
## owns the exit code end to end.

## Test scenes, in the order they run. The last one owns the exit code.
const SUITES: Array[String] = [
	"res://tests/test_interop.tscn",
	"res://tests/test_world.tscn",
]

## Frames to allow for a deferred scene change before deciding it did not take.
const STARTUP_GRACE_FRAMES := 10

## Upper bound on a whole test run. Generous: this is a stuck-run detector, not
## a performance budget. It must stay below the [code]--quit-after[/code] in the
## documented command above, or that fires first and this bound is decorative.
const WATCHDOG_FRAMES := 800

var _frames := 0
var _index := -1
var _suite: Node = null
var _suite_frames := 0
var _reached_last_suite := false


func _initialize() -> void:
	process_frame.connect(_on_process_frame)
	_start_next_suite()


## Runs however the main loop ended, including [code]--quit-after[/code], and
## quit() still sets the process exit code from here.
func _finalize() -> void:
	if _reached_last_suite:
		return
	push_error(
		"tests did not run to completion: stopped in %s after %d frames"
		% [SUITES[_index], _frames]
	)
	quit(1)


func _on_process_frame() -> void:
	_frames += 1
	_suite_frames += 1

	if _frames >= WATCHDOG_FRAMES:
		push_error("tests did not finish within %d frames" % WATCHDOG_FRAMES)
		quit(1)
		return

	var path := SUITES[_index]

	if _suite == null:
		if current_scene != null and current_scene.scene_file_path == path:
			# A scene whose script failed to parse instantiates with no script
			# attached, so its assertions never run. Catch that as a failure
			# rather than letting the run drift to a clean exit.
			if current_scene.get_script() == null:
				push_error("%s loaded but its script did not compile" % path)
				quit(1)
				return
			_suite = current_scene
			_reached_last_suite = _is_last()
			if not _is_last() and not _reports_a_verdict(_suite):
				push_error(
					"%s is not the last suite but does not expose finished/passed" % path
				)
				quit(1)
			return
		if _suite_frames >= STARTUP_GRACE_FRAMES:
			push_error("%s did not become the current scene" % path)
			quit(1)
		return

	# The last suite quits the tree itself; there is nothing here to poll.
	if _is_last():
		return

	if bool(_suite.get("finished")):
		if not bool(_suite.get("passed")):
			push_error("%s reported failures" % path)
			quit(1)
			return
		_start_next_suite()


func _start_next_suite() -> void:
	_index += 1
	_suite = null
	_suite_frames = 0

	var path := SUITES[_index]
	var status := change_scene_to_file(path)
	if status != OK:
		push_error("could not load %s: %d" % [path, status])
		quit(1)


func _is_last() -> bool:
	return _index == SUITES.size() - 1


## A suite reports a verdict when it exposes both properties. A missing one
## reads as null, which a bool cast would silently turn into "still running"
## and then into a watchdog timeout with a misleading message.
func _reports_a_verdict(suite: Node) -> bool:
	return suite.get("finished") != null and suite.get("passed") != null
