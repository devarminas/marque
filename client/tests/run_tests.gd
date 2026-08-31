extends SceneTree

## Headless entry point, per NOTES.md, "Headless testing":
##
## [codeblock]
## godot --headless --path client --script res://tests/run_tests.gd --quit-after 900
## [/codeblock]
##
## Two kinds of suite run here, in this order.
##
## [b]Tree-free suites[/b] are plain [RefCounted] scripts, run from
## [method _initialize] before any scene has been loaded. The pure client logic —
## the tick clock and the polyline walker — is tested this way on purpose: a
## suite that cannot reach a scene tree is proof that the logic under it does not
## need one, which is the practical test of the "game logic never reaches into
## the visual tree" seam in CLAUDE.md. A frame cannot occur inside one, which is
## also what makes the clock's stall test mean anything.
##
## [b]Scene suites[/b] need a real tree: a stepped physics space, a camera in a
## viewport, the authored scenes themselves. They are loaded one after another
## with [method SceneTree.change_scene_to_file] rather than assembled here, so
## the tests exercise the scenes the game ships.
##
## The suites own their assertions. This runner owns the three ways a test run
## can pass by accident:
##
## 1. A scene loads but its script does not compile. Godot attaches no script,
##    nothing asserts, nothing quits, and [code]--quit-after[/code] exits 0.
## 2. The tests hang. Same ending, same false pass.
## 3. A suite runs but asserts nothing. Zero assertions and zero failures is
##    indistinguishable from a pass unless the count is checked.
##
## All three are watched below and all three exit 1.

## Suites that need no scene tree. Order is the order they run in.
const TREE_FREE_SUITES: Array = [
	{"name": "tick clock", "script": preload("res://tests/test_tick_clock.gd")},
	{"name": "polyline walker", "script": preload("res://tests/test_polyline_walker.gd")},
]

## Suites that need a scene tree, run one at a time in this order.
##
## Contract: the scene's root script exposes [code]is_finished() -> bool[/code],
## [code]get_failures() -> PackedStringArray[/code] and
## [code]get_assertion_count() -> int[/code]. It reports; it does not quit. A
## suite that quits is a suite no later suite can run after.
##
## The contract is polled rather than signalled because a scene's
## [method Node._ready] can finish before this runner ever gets a frame in which
## to connect, and a missed signal would look exactly like a hung suite.
const SCENE_SUITES: Array = [
	{"name": "world and camera", "scene": "res://tests/test_world.tscn"},
	{"name": "player avatar", "scene": "res://tests/test_avatar.tscn"},
]

const Assertions := preload("res://tests/assertions.gd")

## Frames to allow for the deferred scene change before checking it took.
const STARTUP_GRACE_FRAMES := 10

## Upper bound on the whole run. A stuck-run detector, not a performance budget:
## the suites here settle in well under 200 frames.
##
## Deliberately below the [code]--quit-after 900[/code] in the documented
## command. [code]--quit-after[/code] exits 0, so a watchdog above it would let a
## hung run report success — the exact false pass this runner exists to catch.
const WATCHDOG_FRAMES := 600

var _frames := 0
var _suite_frames := 0
var _suite_index := -1
var _expected_scene_path := ""
var _failures := PackedStringArray()
var _assertion_count := 0
var _tree_free_completed := 0
## quit() takes effect at the end of the current main-loop iteration, so a frame
## signal can still arrive after the report. Reporting twice would be noise.
var _finished := false


func _initialize() -> void:
	var healthy := _run_tree_free_suites()
	# A runtime error inside a GDScript function aborts that function and hands
	# the caller a null return with no exception to catch, so the boolean above
	# cannot be trusted on its own: a suite that died mid-run unwinds
	# _run_tree_free_suites() and this reads null. Counting what actually
	# finished is the check that survives that.
	if _tree_free_completed != TREE_FREE_SUITES.size():
		_fail(
			"only %d of %d tree-free suite(s) ran to completion"
			% [_tree_free_completed, TREE_FREE_SUITES.size()]
		)
		healthy = false
	if not healthy or SCENE_SUITES.is_empty():
		_report_and_quit()
		return
	process_frame.connect(_on_process_frame)
	_start_scene_suite(0)


## Returns false when a suite failed so badly that the scene suites are not worth
## running: a broken preload here means the whole client logic layer is broken.
func _run_tree_free_suites() -> bool:
	var healthy := true
	for suite in TREE_FREE_SUITES:
		var name: String = suite["name"]
		print("== %s (no scene tree) ==" % name)
		var script: GDScript = suite["script"]
		# A suite whose script failed to parse still preloads, as an unusable
		# GDScript whose new() does not exist. Calling it aborts this function
		# and the run reports a clean pass over the suites that did run.
		if not script.can_instantiate():
			_fail("suite '%s' did not compile" % name)
			return false
		var instance = script.new()
		if instance == null or not instance.has_method("run"):
			_fail("suite '%s' does not implement run(assertions)" % name)
			return false
		var assertions := Assertions.new()
		instance.run(assertions)
		if not assertions.completed:
			_fail("suite '%s' did not run to completion" % name)
			return false
		_tree_free_completed += 1
		if not _absorb(name, assertions.assertion_count, assertions.failures):
			healthy = false
	return healthy


func _start_scene_suite(index: int) -> void:
	_suite_index = index
	_suite_frames = 0
	_expected_scene_path = SCENE_SUITES[index]["scene"]
	print("== %s ==" % SCENE_SUITES[index]["name"])
	var error := change_scene_to_file(_expected_scene_path)
	if error != OK:
		_fail("could not load %s: %d" % [_expected_scene_path, error])
		_report_and_quit()


func _on_process_frame() -> void:
	if _finished:
		return
	_frames += 1
	_suite_frames += 1

	var suite: Dictionary = SCENE_SUITES[_suite_index]
	var scene := current_scene

	if _suite_frames == STARTUP_GRACE_FRAMES and not _check_suite_started(suite, scene):
		_report_and_quit()
		return

	if _frames >= WATCHDOG_FRAMES:
		_fail(
			"tests did not finish within %d frames (stuck in '%s')"
			% [WATCHDOG_FRAMES, suite["name"]]
		)
		_report_and_quit()
		return

	if scene == null or scene.scene_file_path != _expected_scene_path:
		return
	if not scene.has_method("is_finished") or not scene.is_finished():
		return

	if not _absorb(suite["name"], scene.get_assertion_count(), scene.get_failures()):
		_report_and_quit()
		return
	if _suite_index + 1 < SCENE_SUITES.size():
		_start_scene_suite(_suite_index + 1)
		return
	_report_and_quit()


## A scene whose script failed to parse instantiates with no script attached, so
## its assertions never run. Catch that rather than letting the run drift to a
## clean exit.
func _check_suite_started(suite: Dictionary, scene: Node) -> bool:
	if scene == null or scene.scene_file_path != _expected_scene_path:
		_fail("%s did not become the current scene" % _expected_scene_path)
		return false
	if scene.get_script() == null:
		_fail("%s loaded but its script did not compile" % _expected_scene_path)
		return false
	for method in ["is_finished", "get_failures", "get_assertion_count"]:
		if not scene.has_method(method):
			_fail("%s does not implement the suite contract: %s()" % [_expected_scene_path, method])
			return false
	return true


## Folds one suite's result into the run.
##
## Returns false only when the suite is structurally broken, which is worth
## stopping for. A merely failing assertion is not: the point of running the rest
## is that one report names everything wrong rather than the first thing wrong.
func _absorb(name: String, assertion_count: int, failures: PackedStringArray) -> bool:
	print("  -- %d assertion(s), %d failure(s)" % [assertion_count, failures.size()])
	for failure in failures:
		_failures.append("%s: %s" % [name, failure])
	if assertion_count <= 0:
		_fail("suite '%s' ran zero assertions" % name)
		return false
	_assertion_count += assertion_count
	return true


func _fail(message: String) -> void:
	push_error(message)
	_failures.append(message)


func _report_and_quit() -> void:
	if _finished:
		return
	_finished = true
	if _failures.is_empty():
		print("PASS: %d assertion(s) held across %d suite(s)" % [
			_assertion_count, TREE_FREE_SUITES.size() + SCENE_SUITES.size()
		])
		quit(0)
		return
	printerr("FAIL: %d assertion(s) failed of %d" % [_failures.size(), _assertion_count])
	for failure in _failures:
		printerr("  - " + failure)
	quit(1)
