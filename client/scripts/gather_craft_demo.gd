extends RefCounted


func run() -> int:
	var msg := (
		"gather_craft_demo.gd retired under ARM-287 (empty join kit / stale axe+weapon asserts; "
		+ "not on wish+pose+/give verify path). "
		+ "Use gather_error_demo for live gather proof."
	)
	push_error(msg)
	print(msg)
	return 1
