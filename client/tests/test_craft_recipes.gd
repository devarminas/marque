extends RefCounted

const CraftRecipes := preload("res://scripts/craft_recipes.gd")
const Assertions := preload("res://tests/assertions.gd")


func run(assertions: Assertions) -> void:
	_test_bag_recipes_match_server(assertions)
	_test_station_recipes_match_server(assertions)
	_test_partner_slots(assertions)
	assertions.finish()


func _test_bag_recipes_match_server(assertions: Assertions) -> void:
	var logs := CraftRecipes.bag_recipe_for("logs")
	assertions.check(
		not logs.is_empty() and String(logs["produce"]) == "sticks",
		'logs bag recipe produces sticks, got %s' % logs,
	)
	var bar := CraftRecipes.bag_recipe_for("copper_bar")
	assertions.check(
		not bar.is_empty() and String(bar["produce"]) == "sword",
		'copper_bar bag recipe produces sword, got %s' % bar,
	)
	var sticks := CraftRecipes.bag_recipe_for("sticks")
	assertions.check(
		not sticks.is_empty() and String(sticks["produce"]) == "sword",
		'sticks bag recipe produces sword, got %s' % sticks,
	)
	assertions.check(
		CraftRecipes.bag_recipe_for("acorn").is_empty(),
		"acorn has no bag recipe",
	)
	assertions.check(
		CraftRecipes.bag_recipe_for("copper_ore").is_empty(),
		"copper_ore has no bag recipe",
	)
	assertions.check(CraftRecipes.bag_recipe_for("").is_empty(), "empty kind has no bag recipe")


func _test_station_recipes_match_server(assertions: Assertions) -> void:
	assertions.check(
		CraftRecipes.station_kind_for("copper_ore") == "smelter",
		'copper_ore stations at smelter, got "%s"' % CraftRecipes.station_kind_for("copper_ore"),
	)
	assertions.check(
		CraftRecipes.station_produce("smelter", "copper_ore") == "copper_bar",
		'smelter+ore produces copper_bar, got "%s"'
		% CraftRecipes.station_produce("smelter", "copper_ore"),
	)
	assertions.check(
		CraftRecipes.station_kind_for("logs") == "",
		"logs are not a station input",
	)
	assertions.check(
		CraftRecipes.station_produce("smelter", "logs") == "",
		"smelter rejects logs",
	)
	assertions.check(
		CraftRecipes.station_produce("tree", "copper_ore") == "",
		"a tree is not a station",
	)


func _test_partner_slots(assertions: Assertions) -> void:
	var empty := CraftRecipes.partner_slots(0, "logs", PackedInt32Array(), PackedStringArray())
	assertions.check(empty.is_empty(), "empty bag has no partners")

	var logs_self := CraftRecipes.partner_slots(
		2, "logs", PackedInt32Array([2, 4]), PackedStringArray(["logs", "acorn"])
	)
	assertions.check(
		logs_self.size() == 1 and logs_self[0] == 2,
		"complete logs self-use names only the source slot, got %s" % logs_self,
	)

	var incomplete := CraftRecipes.partner_slots(
		0, "copper_bar", PackedInt32Array([0, 1]), PackedStringArray(["copper_bar", "acorn"])
	)
	assertions.check(
		incomplete.is_empty(),
		"copper_bar without sticks has no valid partners, got %s" % incomplete,
	)

	var complete := CraftRecipes.partner_slots(
		0,
		"copper_bar",
		PackedInt32Array([0, 3, 5]),
		PackedStringArray(["copper_bar", "sticks", "acorn"]),
	)
	assertions.check(
		_packed_has(complete, 3) and _packed_has(complete, 0) and not _packed_has(complete, 5),
		"copper_bar+sticks names the sticks slot and source, not acorn, got %s" % complete,
	)

	var from_sticks := CraftRecipes.partner_slots(
		3,
		"sticks",
		PackedInt32Array([0, 3]),
		PackedStringArray(["copper_bar", "sticks"]),
	)
	assertions.check(
		_packed_has(from_sticks, 0) and _packed_has(from_sticks, 3),
		"sticks+bar names the bar slot and source, got %s" % from_sticks,
	)


static func _packed_has(values: PackedInt32Array, needle: int) -> bool:
	for entry in values.size():
		if int(values[entry]) == needle:
			return true
	return false
