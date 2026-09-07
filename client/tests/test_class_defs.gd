extends RefCounted

const ClassDefs := preload("res://scripts/class_defs.gd")
const Assertions := preload("res://tests/assertions.gd")


func run(assertions: Assertions) -> void:
	print("  (ERROR lines below are fail-closed paths under test)")
	_test_shared_starters(assertions)
	_test_skill_starters(assertions)
	_test_class_starters(assertions)
	_test_missing_file_is_empty(assertions)
	_test_malformed_is_empty(assertions)
	_test_empty_is_empty(assertions)
	_test_duplicate_is_empty(assertions)
	assertions.finish()


func _test_shared_starters(assertions: Assertions) -> void:
	var cat: Dictionary = ClassDefs.load_sets()
	var id_list := ClassDefs.set_ids(cat)
	assertions.check(id_list.size() == 5, "shared sets has five sets, got %d" % id_list.size())
	var miner: Variant = ClassDefs.get_set(cat, "miner")
	assertions.check(miner != null, "miner set is present")
	if miner != null:
		var m: Dictionary = miner
		assertions.check(String(m["name"]) == "Miner", "miner set names Miner")
		assertions.check(String(m["slots"]["chest"]) == "prospector_jacket", "miner chest is prospector_jacket")
		assertions.check(String(m["slots"]["boots"]) == "prospector_boots", "miner boots is prospector_boots")
		assertions.check(String(m["tools"]["pickaxe"]["handed"]) == ClassDefs.HANDED_ONE, "miner pickaxe is one-handed")
	var lumberjack: Variant = ClassDefs.get_set(cat, "lumberjack")
	assertions.check(lumberjack != null, "lumberjack set is present")
	if lumberjack != null:
		var lj: Dictionary = lumberjack
		assertions.check(String(lj["slots"]["chest"]) == "forester_shirt", "lumberjack chest is forester_shirt")
		assertions.check(String(lj["tools"]["axe"]["handed"]) == ClassDefs.HANDED_TWO, "lumberjack axe is two-handed")
	assertions.check(id_list.has("knight"), "knight set present")
	assertions.check(id_list.has("mage"), "mage set present")
	assertions.check(id_list.has("archer"), "archer set present")


func _test_skill_starters(assertions: Assertions) -> void:
	var cat: Dictionary = ClassDefs.load_skills()
	var id_list := ClassDefs.skill_ids(cat)
	assertions.check(id_list.size() == 5, "shared skills has five skills, got %d" % id_list.size())
	for id in ["mining", "woodcutting", "combat", "magic", "ranged"]:
		var skill: Variant = ClassDefs.get_skill(cat, id)
		assertions.check(skill != null, "skill %s is present" % id)
		if skill != null:
			var s: Dictionary = skill
			assertions.check(int(s["max_level"]) == 99, "skill %s max_level is 99" % id)


func _test_class_starters(assertions: Assertions) -> void:
	var cat: Dictionary = ClassDefs.load_classes()
	var id_list := ClassDefs.class_ids(cat)
	assertions.check(id_list.size() == 5, "shared classes has five classes, got %d" % id_list.size())
	var miner: Variant = ClassDefs.lookup_class(cat, "miner")
	assertions.check(miner != null, "miner class is present")
	if miner != null:
		assertions.check(
			ClassDefs.class_display_name(cat, "miner") == "Miner",
			"miner class display name is Miner",
		)
	assertions.check(ClassDefs.class_display_name(cat, "") == "", "empty id has no display name")


func _test_missing_file_is_empty(assertions: Assertions) -> void:
	var cat: Dictionary = ClassDefs.load_from_path("res://does_not_exist_sets.json", "sets", "by_set_id")
	assertions.check(ClassDefs.set_ids(cat).is_empty(), "missing sets file yields empty catalog")


func _test_malformed_is_empty(assertions: Assertions) -> void:
	var cat: Dictionary = ClassDefs.parse_text('{"sets":[', "sets", "by_set_id", "<test>")
	assertions.check(ClassDefs.set_ids(cat).is_empty(), "malformed sets JSON yields empty catalog")


func _test_empty_is_empty(assertions: Assertions) -> void:
	var cat: Dictionary = ClassDefs.parse_text('{"sets":[]}', "sets", "by_set_id", "<test>")
	assertions.check(ClassDefs.set_ids(cat).is_empty(), "empty sets array yields empty catalog")


func _test_duplicate_is_empty(assertions: Assertions) -> void:
	var cat: Dictionary = ClassDefs.parse_text(
		'{"sets":[{"id":"miner","name":"Miner","slots":{"chest":"prospector_jacket"},"tools":{}},{"id":"miner","name":"Miner 2","slots":{"chest":"prospector_jacket"},"tools":{}}]}',
		"sets",
		"by_set_id",
		"<test>"
	)
	assertions.check(ClassDefs.set_ids(cat).is_empty(), "duplicate set id yields empty catalog")