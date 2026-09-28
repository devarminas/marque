extends RefCounted

const Assertions := preload("res://tests/assertions.gd")
const FloatingCombatTextScript := preload("res://scripts/floating_combat_text.gd")
const FloatingCombatTextScene := preload("res://scenes/floating_combat_text.tscn")


func run(assertions: Assertions) -> void:
	_test_style_table_white(assertions)
	_test_style_table_crit(assertions)
	_test_style_table_miss(assertions)
	_test_style_table_spell(assertions)
	_test_style_table_heal(assertions)
	_test_crit_larger_than_white(assertions)
	_test_format_text_miss(assertions)
	_test_format_text_heal_prefix(assertions)
	assertions.finish()


func _test_style_table_white(assertions: Assertions) -> void:
	var style := FloatingCombatTextScript.style_for("white", false)
	assertions.check(
		style["color"] == Color(1.0, 1.0, 1.0, 1.0),
		"white hit color is white, got %s" % [style["color"]],
	)
	var text := FloatingCombatTextScript.format_text(7, "white", false)
	assertions.check(text == "7", "white hit text is the number, got '%s'" % text)


func _test_style_table_crit(assertions: Assertions) -> void:
	var style := FloatingCombatTextScript.style_for("white", true)
	assertions.check(
		style["color"] == Color(1.0, 0.85, 0.15, 1.0),
		"crit color is gold, got %s" % [style["color"]],
	)
	var text := FloatingCombatTextScript.format_text(14, "white", true)
	assertions.check(text == "14!", "crit text has exclamation, got '%s'" % text)


func _test_style_table_miss(assertions: Assertions) -> void:
	var style := FloatingCombatTextScript.style_for("miss", false)
	assertions.check(
		style["color"] == Color(0.6, 0.6, 0.6, 1.0),
		"miss color is grey, got %s" % [style["color"]],
	)
	var text := FloatingCombatTextScript.format_text(0, "miss", false)
	assertions.check(text == "Miss", "miss text says Miss, got '%s'" % text)


func _test_style_table_spell(assertions: Assertions) -> void:
	var style := FloatingCombatTextScript.style_for("spell", false)
	assertions.check(
		style["color"] == Color(0.55, 0.7, 1.0, 1.0),
		"spell color is blue, got %s" % [style["color"]],
	)
	var text := FloatingCombatTextScript.format_text(22, "spell", false)
	assertions.check(text == "22", "spell text is the number, got '%s'" % text)


func _test_style_table_heal(assertions: Assertions) -> void:
	var style := FloatingCombatTextScript.style_for("heal", false)
	assertions.check(
		style["color"] == Color(0.35, 0.95, 0.45, 1.0),
		"heal color is green, got %s" % [style["color"]],
	)
	var text := FloatingCombatTextScript.format_text(25, "heal", false)
	assertions.check(text == "+25", "heal text has plus prefix, got '%s'" % text)


func _test_crit_larger_than_white(assertions: Assertions) -> void:
	var white_style := FloatingCombatTextScript.style_for("white", false)
	var crit_style := FloatingCombatTextScript.style_for("white", true)
	assertions.check(
		crit_style["size_mul"] > white_style["size_mul"],
		"crit size_mul %.1f > white size_mul %.1f" % [crit_style["size_mul"], white_style["size_mul"]],
	)


func _test_format_text_miss(assertions: Assertions) -> void:
	# Miss text is always "Miss" regardless of amount.
	var text := FloatingCombatTextScript.format_text(99, "miss", false)
	assertions.check(text == "Miss", "miss always says Miss regardless of amount, got '%s'" % text)


func _test_format_text_heal_prefix(assertions: Assertions) -> void:
	var text := FloatingCombatTextScript.format_text(10, "heal", false)
	assertions.check(text.begins_with("+"), "heal text starts with +, got '%s'" % text)
