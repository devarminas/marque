extends Node3D

## What holding WASD puts on the wire: the camera-relative chord. **ARM-130.**
## Nothing before this suite asserted W and S against the camera rather than
## against a trig formula, and the inversion shipped green in M6g: W walked
## toward the camera while A and D walked correctly, because the session
## negated the chord it already calls forward.
##
## The client under test is [code]main.tscn[/code], instanced here rather than
## authored into the suite's scene so that the session's net node can be
## swapped for [code]tests/stub_move_net.gd[/code] before the session's
## [method Node._ready] resolves its exports. The stub inherits the real
## decoder, so the welcome below goes through the same
## [code]ingest_text_frame[/code] a socket feeds, and the keys go through the
## real action state, so what is pressed is what [code]session.gd[/code] reads.

const MainScene := preload("res://scenes/main.tscn")
const CameraRigScript := preload("res://scripts/camera_rig.gd")
const StubNet := preload("res://tests/stub_move_net.gd")
const Assertions := preload("res://tests/assertions.gd")

## A one-player world at the origin, as [code]test_heartbeat.gd[/code]'s.
const WELCOME := '{"welcome":{"you":1,"tick_ms":150,"tick":100,"players":[{"id":1,"x":0.0,"z":0.0}]}}'

## Yaw the rig is authored with in [code]main.tscn[/code].
const AUTHORED_YAW_DEGREES := 30.0

## The authored rig, camera behind on rig +Z at 30 degrees, gives these.
const CHORD_W := Vector2(-0.5, -0.8660254)
const CHORD_S := Vector2(0.5, 0.8660254)
const CHORD_A := Vector2(-0.8660254, 0.5)
const CHORD_D := Vector2(0.8660254, -0.5)
## Right times forward, unnormalized; the server normalizes.
const CHORD_WD := Vector2(0.3660254, -1.3660254)

## Yaw-0 chords, named as [code]PROTOCOL.md[/code]'s `move` example.
const CHORD_W_YAW0 := Vector2(0.0, -1.0)
const CHORD_S_YAW0 := Vector2(0.0, 1.0)

## Chord the release provokes, clearing the server's sticky steer.
const CHORD_IDLE := Vector2.ZERO

## Chord comparison slack, absorbing float32 transform round-tripping.
const EPSILON := 0.001

## Dot-product floor for "the chord points where the camera looks". Nearly 1:
## a chord right by 90 degrees reads at 0, opposite by 180 degrees at -1.
const VIEW_DOT_MIN := 0.9

## Degrees to orbit past the authored 30 so W is the protocol's own example
## chord. 85.7142857 mouse pixels at the authored
## [code]orbit_degrees_per_pixel = 0.35[/code] is exactly 30 degrees.
const ORBIT_PIXELS_TO_ZERO := 85.7142857

## Frames the input singleton and the session's per-frame poll need to see a
## press and its chord.
const SETTLE_FRAMES := 3

var _assertions := Assertions.new()
var _rig: CameraRigScript
var _stub: StubNet
var _finished := false


## Suite contract, polled by `run_tests.gd`. Reports; never quits.
func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	var main := MainScene.instantiate()
	var net := main.get_node("Session/Net")
	net.set_script(StubNet)
	add_child(main)
	# main.tscn's Session resolves its exported node paths in _ready, and a
	# suite that grabs before that reads nulls that look like scene bugs.
	await get_tree().process_frame
	await get_tree().process_frame

	_rig = main.get_node("CameraRig") as CameraRigScript
	_stub = main.get_node("Session/Net") as StubNet
	_stub.ingest_text_frame(WELCOME)
	await get_tree().process_frame

	print("== move chord: W walks where the camera looks ==")
	await _press_and_read(KEY_W, CHORD_W)
	print("== move chord: S walks where the camera looks from ==")
	await _press_and_read(KEY_S, CHORD_S)
	print("== move chord: A and D strafe the camera's wings ==")
	await _press_and_read(KEY_A, CHORD_A)
	await _press_and_read(KEY_D, CHORD_D)
	print("== move chord: W+D is the unnormalized diagonal ==")
	await _press_and_read(KEY_W, CHORD_WD, [KEY_D])
	print("== move chord: orbiting the camera steers the chord ==")
	_rig.orbit_by(ORBIT_PIXELS_TO_ZERO, 0.0)
	await get_tree().process_frame
	_check(
		is_equal_approx(_rig.get_yaw_degrees(), fposmod(AUTHORED_YAW_DEGREES - 30.0, 360.0)),
		"the orbit brought the yaw to 0, got %f" % _rig.get_yaw_degrees(),
	)
	await _press_and_read(KEY_W, CHORD_W_YAW0)
	await _press_and_read(KEY_S, CHORD_S_YAW0)

	_finished = true


## One case: press [param key] (plus [param extra] keys), read what the session
## sent while held, release, and drop the release's own chord.
##
## The poll repeats a held chord, and a second send after its 100 ms throttle
## is legitimate, so the robust shape is "every new chord is the expected one",
## never "exactly one".
func _press_and_read(key: Key, expected: Vector2, extra: Array = []) -> void:
	var keys: Array = [key]
	keys.append_array(extra)
	for k: Key in keys:
		_set_key(k, true)
	_check_latched(keys)
	var snapshot := _stub.move_chords.size()
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	var new_chords: Array[Vector2] = []
	for index in range(snapshot, _stub.move_chords.size()):
		new_chords.append(_stub.move_chords[index])
	_check(
		not new_chords.is_empty(),
		"holding the keys produced at least one chord, got %d" % new_chords.size(),
	)
	for chord in new_chords:
		_check(
			(chord - expected).length() <= EPSILON,
			"every chord while held is %s, got %s" % [expected, chord],
		)
	if not new_chords.is_empty():
		_check_chord_versus_camera(key, new_chords[0])
	for k: Key in keys:
		_set_key(k, false)
	# The poll that sees the release runs later in the same frame, so the
	# snapshot has to be taken in the same block as the release itself.
	var before_release := _stub.move_chords.size()
	await get_tree().process_frame
	var after_release := _stub.move_chords.size()
	_check(
		after_release == before_release + 1,
		"releasing the keys records exactly one further chord, got %d"
		% (after_release - before_release),
	)
	if after_release == before_release + 1:
		_check(
			_stub.move_chords[before_release] == CHORD_IDLE,
			"and it is the zero chord that clears sticky steer, got %s"
			% _stub.move_chords[before_release],
		)
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	_check(
		_stub.move_chords.size() == after_release,
		"idle frames record no further chords, got %d more"
		% (_stub.move_chords.size() - after_release),
	)


## The semantic core, independent of any trig formula: W's chord is the
## camera's own view direction, read back out of the rig's live transform, and
## S's is its opposite.
func _check_chord_versus_camera(key: Key, chord: Vector2) -> void:
	if key != KEY_W and key != KEY_S:
		return
	var back := _rig.global_transform.basis.z
	var view := Vector2(-back.x, -back.z).normalized()
	var dot := chord.dot(view)
	if key == KEY_W:
		_check(
			dot >= VIEW_DOT_MIN,
			"W sends the direction the camera looks (dot %f vs view %s)" % [dot, view],
		)
	else:
		_check(
			dot <= -VIEW_DOT_MIN,
			"S sends the direction the camera looks from (dot %f vs view %s)" % [dot, view],
		)


## The press must latch the action state the session reads, or every chord
## below is empty and the bug under test is indistinguishable from dead input.
func _check_latched(keys: Array) -> void:
	var actions := {
		KEY_W: "move_forward",
		KEY_S: "move_back",
		KEY_A: "move_left",
		KEY_D: "move_right",
	}
	for k: Key in keys:
		var action: String = actions[k]
		_check(
			Input.is_action_pressed(action),
			"holding %c latches the %s action" % [String.chr(k), action],
		)


## Keys go through the real input pipeline at physical keycodes, so the
## authored InputMap does the mapping a keyboard does.
func _set_key(keycode: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)
