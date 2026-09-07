extends "res://scripts/net_client.gd"


var move_chords: Array[Vector2] = []

func is_open() -> bool:
	return true

func send_move(dx: float, dz: float, seq: int = 0) -> Error:
	move_chords.append(Vector2(dx, dz))
	return OK
