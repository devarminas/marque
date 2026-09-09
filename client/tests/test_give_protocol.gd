extends RefCounted


const NetClientScript := preload("res://scripts/net_client.gd")


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions
	print("== give protocol: give frame shape ==")
	_test_give_frame()
	assertions.finish()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition


func _test_give_frame() -> void:
	_check(
		JSON.stringify(NetClientScript.give_frame(1000003, 3))
		== '{"give":{"npc":1000003,"slot":3}}',
		"give frame names npc and slot",
	)
	var with_seq: Dictionary = NetClientScript.give_frame(1000003, 3, 7)
	var body: Variant = with_seq.get("give")
	_check(body is Dictionary, "give seq frame body is an object, got %s" % [with_seq])
	if body is Dictionary:
		_check(
			int(body.get("npc", 0)) == 1000003
			and int(body.get("slot", -1)) == 3
			and int(body.get("seq", 0)) == 7,
			"give frame carries an explicit seq, got %s" % [with_seq],
		)
	_check(
		(
			JSON.stringify(NetClientScript.dialog_option_frame(1000003, "accept_quest"))
			== '{"dialog_option":{"npc":1000003,"option":"accept_quest"}}'
		),
		"dialog_option frame stays unchanged beside give",
	)
