extends RefCounted


func run(
	_root: Node = null,
	_session = null,
	_inventory = null,
	_dialog = null,
	_party = null,
	_prefix: String = "",
	_role: String = "",
) -> int:
	var msg := (
		"enemy_quest_demo.gd retired under ARM-290 "
		+ "(split into enemy_party + enemy_midchase + enemy_quest_turnin). "
		+ "Use enemy_party_demo, enemy_midchase_demo, or enemy_quest_turnin_demo."
	)
	push_error(msg)
	print(msg)
	return 1
