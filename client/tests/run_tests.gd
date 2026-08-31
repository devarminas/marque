extends SceneTree

## Headless entry point, per NOTES.md, "Headless testing":
##
## [codeblock]
## godot --headless --path client --script res://tests/run_tests.gd
## [/codeblock]
##
## The assertions live in the test scene rather than here, because they need a
## real scene tree: a stepped physics space, a camera in a viewport, and the
## authored ground body from [code]main.tscn[/code]. Loading the scene rather
## than assembling one keeps this unit free of [method Node.add_child].
##
## The test scene owns the exit code on the happy path. This runner owns the two
## ways a test run can pass by accident:
##
## 1. The scene loads but its script does not compile. Godot attaches no script,
##    nothing asserts, nothing quits, and [code]--quit-after[/code] exits 0.
## 2. The tests hang. Same ending, same false pass.
##
## Both are watched below and both exit 1.

const TEST_SCENE := "res://tests/test_world.tscn"
## Frames to allow for the deferred scene change before checking it took.
const STARTUP_GRACE_FRAMES := 10
## Upper bound on a whole test run. Generous: this is a stuck-run detector, not
## a performance budget.
const WATCHDOG_FRAMES := 3000

var _frames := 0


func _initialize() -> void:
	var error := change_scene_to_file(TEST_SCENE)
	if error != OK:
		push_error("could not load %s: %d" % [TEST_SCENE, error])
		quit(1)
		return
	process_frame.connect(_on_process_frame)


func _on_process_frame() -> void:
	_frames += 1

	if _frames == STARTUP_GRACE_FRAMES:
		# A scene whose script failed to parse instantiates with no script
		# attached, so the assertions never run. Catch that as a failure rather
		# than letting the run drift to a clean exit.
		if current_scene == null:
			push_error("%s did not become the current scene" % TEST_SCENE)
			quit(1)
			return
		if current_scene.get_script() == null:
			push_error("%s loaded but its script did not compile" % TEST_SCENE)
			quit(1)
			return

	if _frames >= WATCHDOG_FRAMES:
		push_error("tests did not finish within %d frames" % WATCHDOG_FRAMES)
		quit(1)
