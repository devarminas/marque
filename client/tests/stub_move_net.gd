extends "res://scripts/net_client.gd"

## Test double standing in for the session's net node.
##
## Reports itself open without a socket, so the session's intent paths run
## headless, and records every `move` chord it is asked to send. Frame
## decoding is inherited unchanged, so a test feeds it the same text frames
## a server would.

var move_chords: Array[Vector2] = []

func is_open() -> bool:
	return true

func send_move(dx: float, dz: float, seq: int = 0) -> Error:
	move_chords.append(Vector2(dx, dz))
	return OK
