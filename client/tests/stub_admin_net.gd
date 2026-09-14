extends "res://tests/stub_move_net.gd"


var admin_lines: PackedStringArray = PackedStringArray()
var force_closed := false


func is_open() -> bool:
	if force_closed:
		return false
	return true


func send_admin(line: String, seq: int = 0) -> Error:
	admin_lines.append(line)
	return OK
