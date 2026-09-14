extends RefCounted

## ARM-284: two-client PvP combat_demo is retired. Accidental invocation fails closed.
## Drive dummy_attack_demo / tab_combat_demo for Combat-class vs NPC proof.


func run(
	_root: Node = null,
	_session = null,
	_death = null,
	_hp_hud = null,
	_prefix: String = "",
	_role: String = "",
) -> int:
	var msg := (
		"combat_demo.gd retired under ARM-284 (PvP attack is refused). "
		+ "Use dummy_attack_demo or tab_combat_demo."
	)
	push_error(msg)
	print(msg)
	return 1
