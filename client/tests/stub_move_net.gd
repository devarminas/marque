extends "res://scripts/net_client.gd"


var move_chords: Array[Vector2] = []

func is_open() -> bool:
	return true

var jump_edges: Array[bool] = []

func send_move(dx: float, dz: float, seq: int = 0, jump: bool = false) -> Error:
	move_chords.append(Vector2(dx, dz))
	jump_edges.append(jump)
	return OK
