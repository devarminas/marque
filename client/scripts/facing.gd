extends RefCounted


static func yaw_facing(heading: Vector2) -> float:
	return atan2(-heading.x, -heading.y)


static func turn_toward(current_yaw: float, desired_yaw: float, rate_degrees_per_second: float, delta: float) -> float:
	return rotate_toward(current_yaw, desired_yaw, deg_to_rad(rate_degrees_per_second) * delta)
