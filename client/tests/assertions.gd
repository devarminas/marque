extends RefCounted


var failures := PackedStringArray()
var assertion_count := 0
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
