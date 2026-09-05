extends RefCounted

const AbilityDefs := preload("res://scripts/ability_defs.gd")
const Assertions := preload("res://tests/assertions.gd")


func run(assertions: Assertions) -> void:
	print("  (ERROR lines below are fail-closed paths under test)")
	_test_shared_starters(assertions)
	_test_missing_file_is_empty(assertions)
	_test_malformed_is_empty(assertions)
	_test_empty_abilities_is_empty(assertions)
	assertions.finish()


func _test_shared_starters(assertions: Assertions) -> void:
	var cat: Dictionary = AbilityDefs.load_default()
	var id_list := AbilityDefs.ids(cat)
	assertions.check(id_list.size() == 2, "shared table has two abilities, got %d" % id_list.size())
	var heal: Variant = AbilityDefs.get_ability(cat, "heal")
	assertions.check(heal != null, "heal is present")
	if heal != null:
		var h: Dictionary = heal
		assertions.check(String(h["target"]) == AbilityDefs.TARGET_FRIENDLY, "heal targets friendly")
		assertions.check(String(h["effect"]["kind"]) == AbilityDefs.EFFECT_HEAL, "heal effect is heal")
		assertions.check(String(h["ui"]["color"]) == "green", "heal UI hint is green")
		assertions.check(float(h["mana_cost"]) > 0.0, "heal has mana_cost")
	var fireball: Variant = AbilityDefs.get_ability(cat, "fireball")
	assertions.check(fireball != null, "fireball is present")
	if fireball != null:
		var f: Dictionary = fireball
		assertions.check(String(f["target"]) == AbilityDefs.TARGET_HOSTILE, "fireball targets hostile")
		assertions.check(String(f["effect"]["kind"]) == AbilityDefs.EFFECT_DAMAGE, "fireball effect is damage")
		assertions.check(String(f["ui"]["color"]) == "red", "fireball UI hint is red")
		assertions.check(float(f["range"]) > 0.0, "fireball has range")


func _test_missing_file_is_empty(assertions: Assertions) -> void:
	var cat: Dictionary = AbilityDefs.load_from_path("res://does_not_exist_abilities.json")
	assertions.check(AbilityDefs.ids(cat).is_empty(), "missing file yields empty catalog")
	assertions.check(AbilityDefs.get_ability(cat, "heal") == null, "missing file invents no heal")


func _test_malformed_is_empty(assertions: Assertions) -> void:
	var cat: Dictionary = AbilityDefs.parse_text('{"abilities":[', "<test>")
	assertions.check(AbilityDefs.ids(cat).is_empty(), "malformed JSON yields empty catalog")


func _test_empty_abilities_is_empty(assertions: Assertions) -> void:
	var cat: Dictionary = AbilityDefs.parse_text('{"abilities":[]}', "<test>")
	assertions.check(AbilityDefs.ids(cat).is_empty(), "empty abilities array yields empty catalog")
	assertions.check(AbilityDefs.get_ability(cat, "fireball") == null, "empty catalog invents no fireball")
