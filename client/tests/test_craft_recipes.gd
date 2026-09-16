extends RefCounted

const CraftRecipes := preload("res://scripts/craft_recipes.gd")
const Assertions := preload("res://tests/assertions.gd")


func run(assertions: Assertions) -> void:
	_test_bag_recipes_match_server(assertions)
	_test_station_recipes_match_server(assertions)
	_test_partner_slots(assertions)
	_test_preview_copy(assertions)
	_test_station_sheet_rows(assertions)
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


func _test_preview_copy(assertions: Assertions) -> void:
	var logs := CraftRecipes.bag_preview("logs", PackedStringArray(["logs"]))
	assertions.check(
		String(logs.get("text", "")) == "Craft → Sticks" and bool(logs.get("complete", false)),
		'logs preview is "Craft → Sticks", got %s' % logs,
	)
	var sword := CraftRecipes.bag_preview(
		"copper_bar", PackedStringArray(["copper_bar", "sticks"])
	)
	assertions.check(
		String(sword.get("text", "")) == "Craft → Sword" and bool(sword.get("complete", false)),
		'bar+sticks preview is "Craft → Sword", got %s' % sword,
	)
	var missing := CraftRecipes.bag_preview("copper_bar", PackedStringArray(["copper_bar"]))
	assertions.check(
		String(missing.get("text", "")) == "Craft → Sword (missing Sticks)"
		and not bool(missing.get("complete", true)),
		'bar without sticks marks missing Sticks, got %s' % missing,
	)
	var smelt := CraftRecipes.station_preview("smelter", "copper_ore")
	assertions.check(
		String(smelt.get("text", "")) == "Smelt → Copper bar",
		'smelter+ore preview is "Smelt → Copper bar", got %s' % smelt,
	)
	assertions.check(
		CraftRecipes.bag_preview("acorn", PackedStringArray(["acorn"])).is_empty(),
		"acorn has no bag preview",
	)
	assertions.check(
		CraftRecipes.station_preview("smelter", "logs").is_empty(),
		"logs on a smelter have no station preview",
	)


func _test_station_sheet_rows(assertions: Assertions) -> void:
	var empty := CraftRecipes.station_sheet_rows("smelter", PackedStringArray())
	assertions.check(
		empty.size() == 1
		and String(empty[0].get("text", "")) == "Copper ore → Copper bar"
		and not bool(empty[0].get("ready", true)),
		"empty bag lists the smelter recipe as not ready, got %s" % empty,
	)
	var ready := CraftRecipes.station_sheet_rows("smelter", PackedStringArray(["copper_ore"]))
	assertions.check(
		ready.size() == 1 and bool(ready[0].get("ready", false)),
		"ore in the bag marks the smelter recipe ready, got %s" % ready,
	)
	var sticks := CraftRecipes.station_sheet_rows("smelter", PackedStringArray(["sticks"]))
	assertions.check(
		sticks.size() == 1 and not bool(sticks[0].get("ready", true)),
		"sticks do not make the smelter recipe ready, got %s" % sticks,
	)
	assertions.check(
		CraftRecipes.station_recipes("smith").is_empty(),
		"smith has no recipes until that station kind exists",
	)
	assertions.check(
		CraftRecipes.station_recipes("tree").is_empty(),
		"a tree is not a station sheet",
	)


static func _packed_has(values: PackedInt32Array, needle: int) -> bool:
	for entry in values.size():
		if int(values[entry]) == needle:
			return true
	return false
