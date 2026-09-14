extends RefCounted


func run() -> int:
	var msg := (
		"combat_demo.gd retired under ARM-284 (PvP attack is refused). "
		+ "Use dummy_attack_demo or tab_combat_demo."
	)
	push_error(msg)
	print(msg)
	return 1
