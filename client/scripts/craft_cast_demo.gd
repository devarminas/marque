extends RefCounted


func run(
	_root: Node = null,
	_session = null,
	_inventory = null,
	_equipment = null,
	_cast_bar = null,
	_prefix: String = "",
) -> int:
	var msg := (
		"craft_cast_demo.gd retired under ARM-290 (split into mine_smelt_craft + cast_bar). "
		+ "Use mine_smelt_craft_demo or cast_bar_demo."
	)
	push_error(msg)
	print(msg)
	return 1
