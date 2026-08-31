extends RefCounted

## Assertion tally shared by the test suites.
##
## Counts what ran as well as what failed. "Zero assertions ran" is the failure
## mode NOTES.md warns about — a suite that never executes looks exactly like a
## suite that passed — so the count is part of the result, not a debug aid.
##
## Typed by [code]preload[/code], per NOTES.md, "Godot authoring traps".

var failures := PackedStringArray()
var assertion_count := 0
## Set by [method finish], which a suite calls as the last thing it does.
##
## A runtime error inside a GDScript function aborts that function and hands the
## caller a null return, silently. Without an explicit end-of-suite marker, a
## suite that died halfway is indistinguishable from one that passed: it has
## assertions, it has no failures, and it never said so. This is the tree-free
## half of NOTES.md's "tests did not finish" failure mode; the scene half is the
## runner's watchdog.
var completed := false


func finish() -> void:
	completed = true


func check(condition: bool, message: String) -> void:
	assertion_count += 1
	if condition:
		print("  ok    " + message)
		return
	failures.append(message)
	print("  FAIL  " + message)


func check_near(actual: float, expected: float, epsilon: float, message: String) -> void:
	check(
		is_finite(actual) and absf(actual - expected) <= epsilon,
		"%s (expected %.6f +/- %.6f, got %.6f)" % [message, expected, epsilon, actual],
	)


func check_position_near(
	actual: Vector2, expected: Vector2, epsilon: float, message: String
) -> void:
	# is_finite on both components first: a NaN comparison is false, which reads
	# in the log as an ordinary numeric miss rather than as the NaN it is.
	var finite := is_finite(actual.x) and is_finite(actual.y)
	check(
		finite and absf(actual.x - expected.x) <= epsilon and absf(actual.y - expected.y) <= epsilon,
		"%s (expected (%.6f, %.6f) +/- %.6f, got (%.6f, %.6f), finite=%s)"
		% [message, expected.x, expected.y, epsilon, actual.x, actual.y, finite],
	)


func check_finite(actual: Vector2, message: String) -> void:
	check(
		is_finite(actual.x) and is_finite(actual.y),
		"%s (got (%f, %f))" % [message, actual.x, actual.y],
	)
