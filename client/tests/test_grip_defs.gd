extends RefCounted

const GripDefs := preload("res://scripts/grip_defs.gd")
const Assertions := preload("res://tests/assertions.gd")

const TWO_HANDED_KINDS := ["staff", "bow", "lumberjack_axe"]


func run(assertions: Assertions) -> void:
	print("  (ERROR lines below are fail-closed paths under test)")
	_test_empty_equipment_leaves_both_hands_empty(assertions)
	_test_one_handed_kinds_land_in_the_slot_the_server_named(assertions)
	_test_two_different_kinds_keep_both_hands(assertions)
	_test_the_same_kind_in_both_hands_collapses_to_the_grip_hand(assertions)
	_test_wire_order_does_not_change_the_plan(assertions)
	_test_slots_that_are_not_hands_are_ignored(assertions)
	_test_ragged_arrays_yield_an_empty_plan(assertions)
	_test_names_the_hands_reads_the_worn_slot_list(assertions)
	assertions.finish()


func _test_empty_equipment_leaves_both_hands_empty(assertions: Assertions) -> void:
	var plan := GripDefs.grip_plan(PackedStringArray(), PackedStringArray())
	assertions.check(
		plan.size() == 2 and plan.has(GripDefs.OFF_HAND) and plan.has(GripDefs.GRIP_HAND),
		"an empty plan still carries exactly the two hand keys, got %s" % [plan.keys()],
	)
	assertions.check(
		plan[GripDefs.OFF_HAND] == "" and plan[GripDefs.GRIP_HAND] == "",
		"bare equipment leaves both hands empty, got %s" % [plan],
	)


func _test_one_handed_kinds_land_in_the_slot_the_server_named(assertions: Assertions) -> void:
	var right := GripDefs.grip_plan(
		PackedStringArray([GripDefs.GRIP_HAND]), PackedStringArray(["sword"])
	)
	assertions.check(
		right[GripDefs.GRIP_HAND] == "sword",
		'a sword in "%s" grips there, got "%s"' % [GripDefs.GRIP_HAND, right[GripDefs.GRIP_HAND]],
	)
	assertions.check(
		right[GripDefs.OFF_HAND] == "",
		"and leaves the off hand empty, got \"%s\"" % right[GripDefs.OFF_HAND],
	)

	var left := GripDefs.grip_plan(
		PackedStringArray([GripDefs.OFF_HAND]), PackedStringArray(["shield"])
	)
	assertions.check(
		left[GripDefs.OFF_HAND] == "shield",
		'a shield in "%s" grips there, got "%s"' % [GripDefs.OFF_HAND, left[GripDefs.OFF_HAND]],
	)
	assertions.check(
		left[GripDefs.GRIP_HAND] == "",
		"and leaves the grip hand empty, got \"%s\"" % left[GripDefs.GRIP_HAND],
	)


func _test_two_different_kinds_keep_both_hands(assertions: Assertions) -> void:
	var plan := GripDefs.grip_plan(
		PackedStringArray([GripDefs.GRIP_HAND, GripDefs.OFF_HAND]),
		PackedStringArray(["sword", "shield"]),
	)
	assertions.check(
		plan[GripDefs.GRIP_HAND] == "sword" and plan[GripDefs.OFF_HAND] == "shield",
		"sword and shield are two one-handed kinds, so both hands stay filled, got %s" % [plan],
	)


func _test_the_same_kind_in_both_hands_collapses_to_the_grip_hand(
	assertions: Assertions
) -> void:
	for kind: String in TWO_HANDED_KINDS:
		var plan := GripDefs.grip_plan(
			PackedStringArray([GripDefs.OFF_HAND, GripDefs.GRIP_HAND]),
			PackedStringArray([kind, kind]),
		)
		assertions.check(
			plan[GripDefs.GRIP_HAND] == kind,
			"%s occupying both hands renders in the grip hand, got \"%s\""
			% [kind, plan[GripDefs.GRIP_HAND]],
		)
		assertions.check(
			plan[GripDefs.OFF_HAND] == "",
			"and the off hand stays empty rather than drawing %s twice, got \"%s\""
			% [kind, plan[GripDefs.OFF_HAND]],
		)


func _test_wire_order_does_not_change_the_plan(assertions: Assertions) -> void:
	var forward := GripDefs.grip_plan(
		PackedStringArray([GripDefs.OFF_HAND, GripDefs.GRIP_HAND]),
		PackedStringArray(["staff", "staff"]),
	)
	var reversed := GripDefs.grip_plan(
		PackedStringArray([GripDefs.GRIP_HAND, GripDefs.OFF_HAND]),
		PackedStringArray(["staff", "staff"]),
	)
	assertions.check(
		forward == reversed,
		"both hands are read before either collapses, so wire order cannot matter; %s vs %s"
		% [forward, reversed],
	)
	assertions.check(
		reversed[GripDefs.GRIP_HAND] == "staff" and reversed[GripDefs.OFF_HAND] == "",
		"and the reversed frame still grips the staff once, got %s" % [reversed],
	)


func _test_slots_that_are_not_hands_are_ignored(assertions: Assertions) -> void:
	var plan := GripDefs.grip_plan(
		PackedStringArray(["helmet", "chest", GripDefs.GRIP_HAND, "feet", "trousers"]),
		PackedStringArray(
			["plate_helm", "plate_chest", "pickaxe", "prospector_boots", "plate_legs"]
		),
	)
	assertions.check(
		plan.size() == 2,
		"armour slots grow no keys on the plan, got %s" % [plan.keys()],
	)
	assertions.check(
		plan[GripDefs.GRIP_HAND] == "pickaxe" and plan[GripDefs.OFF_HAND] == "",
		"a full armour restatement still resolves the one held tool, got %s" % [plan],
	)


func _test_ragged_arrays_yield_an_empty_plan(assertions: Assertions) -> void:
	var plan := GripDefs.grip_plan(
		PackedStringArray([GripDefs.OFF_HAND, GripDefs.GRIP_HAND]), PackedStringArray(["sword"])
	)
	assertions.check(
		plan[GripDefs.OFF_HAND] == "" and plan[GripDefs.GRIP_HAND] == "",
		"ragged slot arrays grip nothing rather than guessing, got %s" % [plan],
	)


func _test_names_the_hands_reads_the_worn_slot_list(assertions: Assertions) -> void:
	assertions.check(
		GripDefs.names_the_hands(
			PackedStringArray(
				["helmet", GripDefs.OFF_HAND, "chest", GripDefs.GRIP_HAND, "feet", "trousers"]
			)
		),
		"the shipped six worn slots name both hands",
	)
	assertions.check(
		not GripDefs.names_the_hands(PackedStringArray(["helmet", "chest", "feet", "trousers"])),
		"a worn list with no hands is refused, so a server slot rename fails loudly",
	)
	assertions.check(
		not GripDefs.names_the_hands(PackedStringArray([GripDefs.OFF_HAND])),
		"and one hand alone is not enough",
	)
	assertions.check(
		not GripDefs.names_the_hands(PackedStringArray()),
		"and an empty worn list is refused",
	)
