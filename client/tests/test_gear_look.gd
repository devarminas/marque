extends RefCounted

const ArtContract := preload("res://scripts/art_contract.gd")
const Assertions := preload("res://tests/assertions.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const GearLook := preload("res://scripts/gear_look.gd")
const GripDefs := preload("res://scripts/grip_defs.gd")

const KIT_GRIPS := {"knight": &"one", "mage": &"two", "archer": &"two", "miner": &"one", "lumberjack": &"two"}


func run(assertions: Assertions) -> void:
	var contract := ArtContract.new(ArtContract.read_text(ArtContract.PATH))
	var sets := ClassDefs.load_sets()
	assertions.check(contract.is_valid(), "the art contract parses clean, got %s" % [contract.errors])
	_test_every_set_kit(assertions, contract, sets)
	_test_the_knight_hides_everything_its_plate_covers(assertions, contract, sets)
	_test_an_empty_snapshot_is_the_bare_body(assertions, contract, sets)
	_test_a_two_handed_staff(assertions, contract, sets)
	_test_sword_and_shield(assertions, contract, sets)
	_test_an_unknown_kind_skips_only_its_slot(assertions, contract, sets)
	_test_resolving_twice_gives_the_same_look(assertions, contract, sets)
	assertions.finish()


func _test_every_set_kit(assertions: Assertions, contract: ArtContract, sets: Dictionary) -> void:
	assertions.check(ClassDefs.set_ids(sets).size() == KIT_GRIPS.size(), "sets.json ships the %d kits under test" % KIT_GRIPS.size())
	for set_id in ClassDefs.set_ids(sets):
		var kit := _kit(sets, set_id)
		var look := GearLook.resolve(kit[0], kit[1], contract, sets)
		var slots: Dictionary = ClassDefs.get_set(sets, set_id)["slots"]
		var expected := PackedStringArray(slots.values())
		expected.sort()
		var hidden := {}
		for item: String in expected:
			for region in contract.pieces[item].hides:
				hidden[region] = true
		var expected_hidden := PackedStringArray(hidden.keys())
		expected_hidden.sort()
		assertions.check(look.pieces == expected, "%s shows its pieces %s, got %s" % [set_id, expected, look.pieces])
		assertions.check(
			look.hidden_regions == expected_hidden,
			"%s hides the union of its pieces' regions %s, got %s" % [set_id, expected_hidden, look.hidden_regions],
		)
		assertions.check(look.grip == KIT_GRIPS.get(set_id), "%s grips %s, got %s" % [set_id, KIT_GRIPS.get(set_id), look.grip])


func _test_the_knight_hides_everything_its_plate_covers(assertions: Assertions, contract: ArtContract, sets: Dictionary) -> void:
	var kit := _kit(sets, "knight")
	var look := GearLook.resolve(kit[0], kit[1], contract, sets)
	var expected := PackedStringArray(["forearms", "head", "hips", "shins", "thighs", "torso", "upper_arms"])
	assertions.check(look.hidden_regions == expected, "the knight hides %s, got %s" % [expected, look.hidden_regions])
	assertions.check(
		look.hands == {GripDefs.OFF_HAND: "shield", GripDefs.GRIP_HAND: "sword"},
		"the knight holds a shield and a sword, got %s" % [look.hands],
	)


func _test_an_empty_snapshot_is_the_bare_body(assertions: Assertions, contract: ArtContract, sets: Dictionary) -> void:
	var look := GearLook.resolve(PackedStringArray(), PackedStringArray(), contract, sets)
	assertions.check(look.pieces.is_empty() and look.hidden_regions.is_empty(), "nothing worn shows no piece and hides no region")
	assertions.check(
		look.hands == {GripDefs.OFF_HAND: "", GripDefs.GRIP_HAND: ""} and look.grip == GearLook.GRIP_NONE,
		"and holds nothing with grip none, got %s %s" % [look.hands, look.grip],
	)


func _test_a_two_handed_staff(assertions: Assertions, contract: ArtContract, sets: Dictionary) -> void:
	var look := GearLook.resolve(
		PackedStringArray([GripDefs.OFF_HAND, GripDefs.GRIP_HAND]), PackedStringArray(["staff", "staff"]), contract, sets
	)
	assertions.check(
		look.hands == {GripDefs.OFF_HAND: "", GripDefs.GRIP_HAND: "staff"},
		"a staff in both hands draws once in the grip hand, got %s" % [look.hands],
	)
	assertions.check(look.grip == GearLook.GRIP_TWO, "and grips two, got %s" % look.grip)


func _test_sword_and_shield(assertions: Assertions, contract: ArtContract, sets: Dictionary) -> void:
	var look := GearLook.resolve(
		PackedStringArray([GripDefs.GRIP_HAND, GripDefs.OFF_HAND]), PackedStringArray(["sword", "shield"]), contract, sets
	)
	assertions.check(
		look.hands == {GripDefs.OFF_HAND: "shield", GripDefs.GRIP_HAND: "sword"} and look.grip == GearLook.GRIP_ONE,
		"sword and shield fill both hands with grip one, got %s %s" % [look.hands, look.grip],
	)
	var sword_only := GearLook.resolve(PackedStringArray([GripDefs.GRIP_HAND]), PackedStringArray(["sword"]), contract, sets)
	assertions.check(sword_only.grip == GearLook.GRIP_ONE, "a lone sword grips one, got %s" % sword_only.grip)


func _test_an_unknown_kind_skips_only_its_slot(assertions: Assertions, contract: ArtContract, sets: Dictionary) -> void:
	print("  (the two ERROR lines below are fail-closed paths under test)")
	var look := GearLook.resolve(
		PackedStringArray(["helmet", "chest", "trousers"]),
		PackedStringArray(["mystery_hat", "plate_chest", "plate_helm"]),
		contract,
		sets,
	)
	assertions.check(
		look.pieces == PackedStringArray(["plate_chest"]),
		"an unknown helmet kind and a helm worn as trousers show nothing, the chest still shows, got %s" % look.pieces,
	)
	assertions.check(
		look.hidden_regions == PackedStringArray(["forearms", "torso", "upper_arms"]),
		"and only the chest hides its regions, got %s" % look.hidden_regions,
	)


func _test_resolving_twice_gives_the_same_look(assertions: Assertions, contract: ArtContract, sets: Dictionary) -> void:
	var kit := _kit(sets, "miner")
	var first := GearLook.resolve(kit[0], kit[1], contract, sets)
	var second := GearLook.resolve(kit[0], kit[1], contract, sets)
	assertions.check(
		first.pieces == second.pieces
		and first.hidden_regions == second.hidden_regions
		and first.hands == second.hands
		and first.grip == second.grip,
		"resolving the miner kit twice gives the same look",
	)


func _kit(sets: Dictionary, set_id: String) -> Array:
	var record: Dictionary = ClassDefs.get_set(sets, set_id)
	var names := PackedStringArray()
	var kinds := PackedStringArray()
	for slot: String in record["slots"]:
		names.append(slot)
		kinds.append(record["slots"][slot])
	for kind: String in record["tools"]:
		var tool: Dictionary = record["tools"][kind]
		var hands := [tool.get("slot", "")]
		if tool["handed"] == ClassDefs.HANDED_TWO:
			hands = [GripDefs.OFF_HAND, GripDefs.GRIP_HAND]
		for hand: String in hands:
			names.append(hand)
			kinds.append(kind)
	return [names, kinds]
