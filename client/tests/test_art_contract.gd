extends RefCounted

const ArtContract := preload("res://scripts/art_contract.gd")
const Assertions := preload("res://tests/assertions.gd")

const BONE_COUNT := 23
const IMP_PELVIS_HEIGHT := 0.62
const IMP_PELVIS_EPSILON := 0.01


func run(assertions: Assertions) -> void:
	print("  (ERROR lines below are fail-closed paths under test)")
	var text := ArtContract.read_text(ArtContract.PATH)
	_test_the_committed_contract_is_valid(assertions, text)
	_test_regions_partition_every_bone_but_the_root(assertions, text)
	_test_slots_own_disjoint_regions(assertions, text)
	_test_every_clip_is_reached_through_a_fallback_route(assertions, text)
	_test_an_unknown_key_falls_back_and_an_unknown_action_is_refused(assertions, text)
	_test_the_imp_stands_at_its_own_pelvis_height(assertions, text)
	_test_each_violation_is_named(assertions, text)
	assertions.finish()


func _test_the_committed_contract_is_valid(assertions: Assertions, text: String) -> void:
	var contract := ArtContract.new(text)
	assertions.check(contract.is_valid(), "the committed contract parses clean, got %s" % [contract.errors])
	assertions.check(
		contract.bones.size() == BONE_COUNT,
		"it declares %d bones, got %d" % [BONE_COUNT, contract.bones.size()],
	)
	assertions.check(
		contract.variants.has("human") and contract.variants.has("imp"),
		"it declares the human and imp variants, got %s" % [contract.variants.keys()],
	)


func _test_regions_partition_every_bone_but_the_root(assertions: Assertions, text: String) -> void:
	var contract := ArtContract.new(text)
	var covered := PackedStringArray()
	for region in contract.regions:
		covered.append_array(contract.regions[region])
	var expected := contract.bone_names()
	expected.remove_at(0)
	covered.sort()
	expected.sort()
	assertions.check(
		covered == expected,
		"the regions cover every bone but root exactly once, got %s" % [covered],
	)


func _test_slots_own_disjoint_regions(assertions: Assertions, text: String) -> void:
	var contract := ArtContract.new(text)
	var owned := PackedStringArray()
	for slot in contract.slot_regions:
		owned.append_array(contract.slot_regions[slot])
	var unique := {}
	for region in owned:
		unique[region] = true
	assertions.check(
		unique.size() == owned.size() and not owned.has("hands"),
		"no region belongs to two slots and hands belong to none, got %s" % [owned],
	)


func _test_every_clip_is_reached_through_a_fallback_route(assertions: Assertions, text: String) -> void:
	var contract := ArtContract.new(text)
	var reached := {}
	for action in contract.actions():
		reached[contract.clip_for(action, ArtContract.FALLBACK_KEY)] = true
	var clips: Array = contract.clips.keys()
	clips.sort()
	var reached_clips: Array = reached.keys()
	reached_clips.sort()
	assertions.check(
		reached_clips == clips,
		"the fallback routes reach every clip %s, got %s" % [clips, reached_clips],
	)


func _test_an_unknown_key_falls_back_and_an_unknown_action_is_refused(
	assertions: Assertions, text: String
) -> void:
	var contract := ArtContract.new(text)
	assertions.check(
		contract.clip_for("swing", "two") == contract.clip_for("swing", ArtContract.FALLBACK_KEY),
		'swing with an unrouted key "two" plays the fallback clip, got %s' % contract.clip_for("swing", "two"),
	)
	assertions.check(
		contract.clip_for("dance", "") == "",
		"an action with no route resolves to no clip",
	)


func _test_the_imp_stands_at_its_own_pelvis_height(assertions: Assertions, text: String) -> void:
	var contract := ArtContract.new(text)
	var pelvis: ArtContract.Bone = contract.bones[contract.bone_names().find("pelvis")]
	assertions.check_near(
		pelvis.head.z * contract.variants["imp"].scale,
		IMP_PELVIS_HEIGHT,
		IMP_PELVIS_EPSILON,
		"the imp variant puts its pelvis near %.2f m" % IMP_PELVIS_HEIGHT,
	)
	assertions.check_near(
		contract.motion_scale("imp"),
		contract.variants["imp"].scale / contract.variants[contract.clip_rig].scale,
		1.0e-9,
		"the imp motion scale is its scale over the clip rig's",
	)


func _test_each_violation_is_named(assertions: Assertions, text: String) -> void:
	var cases := [
		["a repeated bone name", "bone pelvis is declared twice",
			func(raw: Dictionary): raw["bones"][2]["name"] = "pelvis"],
		["a parent declared after its child", "names parent spine_01 before it is declared",
			func(raw: Dictionary): raw["bones"][1]["parent"] = "spine_01"],
		["a second parentless bone", "only the first bone is the root",
			func(raw: Dictionary): raw["bones"][5]["parent"] = null],
		["a two-number head", "head must be three numbers",
			func(raw: Dictionary): raw["bones"][3]["head"] = [0.0, 1.0]],
		["a non-positive variant scale", "variant imp scale must be positive",
			func(raw: Dictionary): raw["variants"]["imp"]["scale"] = 0.0],
		["a clip rig that is not a variant", "clip_rig ogre is not a declared variant",
			func(raw: Dictionary): raw["clip_rig"] = "ogre"],
		["a region naming an unknown bone", "region head names unknown bone tail_01",
			func(raw: Dictionary): raw["regions"]["head"].append("tail_01")],
		["a bone in two regions", "bone Head is in regions head and torso",
			func(raw: Dictionary): raw["regions"]["torso"].append("Head")],
		["a bone in no region", "bone hand_r belongs to no region",
			func(raw: Dictionary): raw["regions"]["hands"] = ["hand_l"]],
		["the root in a region", "root bone root must not belong to a region",
			func(raw: Dictionary): raw["regions"]["hips"].append("root")],
		["a slot owning an unknown region", "slot helmet owns unknown region crown",
			func(raw: Dictionary): raw["slot_regions"]["helmet"] = ["crown"]],
		["a region owned by two slots", "region shins is owned by slots trousers and feet",
			func(raw: Dictionary): raw["slot_regions"]["feet"].append("shins")],
		["a zero-frame clip", "clip idle frames must be a positive integer",
			func(raw: Dictionary): raw["clips"]["idle"]["frames"] = 0.0],
		["a route to an unknown clip", 'route swing/"" names unknown clip slash',
			func(raw: Dictionary): raw["routes"][2]["clip"] = "slash"],
		["an action with no fallback row", 'action swing has no fallback route with key ""',
			func(raw: Dictionary): raw["routes"][2]["key"] = "two"],
		["a repeated route", 'route walk/"" is declared twice',
			func(raw: Dictionary): raw["routes"].append(raw["routes"][1].duplicate())],
		["a clip no route reaches", "clip jump is not routed by any action",
			func(raw: Dictionary): raw["clips"]["jump"] = {"frames": 20.0, "loop": true}],
	]
	for case in cases:
		var raw: Dictionary = (JSON.parse_string(text) as Dictionary).duplicate(true)
		(case[2] as Callable).call(raw)
		var contract := ArtContract.new(JSON.stringify(raw, "", false))
		assertions.check(
			_names_violation(contract.errors, case[1]),
			'%s is refused with "%s", got %s' % [case[0], case[1], contract.errors],
		)
	var garbage := ArtContract.new("[]")
	assertions.check(
		garbage.errors == PackedStringArray(["contract is not a JSON object"]),
		"a non-object document is refused, got %s" % [garbage.errors],
	)


func _names_violation(errors: PackedStringArray, expected: String) -> bool:
	for error in errors:
		if error.contains(expected):
			return true
	return false
