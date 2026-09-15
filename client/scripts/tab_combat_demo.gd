extends RefCounted


func run(_root: Node = null, _session = null, _prefix: String = "") -> int:
	var msg := (
		"tab_combat_demo.gd retired under ARM-290 (split into focused units). "
		+ "Use wasd_demo, dummy_cast_demo, dummy_attack_demo, or heal_wounded_demo."
	)
	push_error(msg)
	print(msg)
	return 1
