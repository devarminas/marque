extends RefCounted


const WALK_SPEED := 3.0
const TICK_DURATION_SEC := 0.04
const WORLD_HALF_EXTENT := 128.0
const STEER_EPSILON := 1e-6
const MIN_PATH_LENGTH := 1e-3
const STEP_DISTANCE := WALK_SPEED * TICK_DURATION_SEC
const JUMP_SPEED := 5.0
const GRAVITY := 20.0


static func wish_to_steer(dx: float, dz: float) -> Vector2:
	var length := Vector2(dx, dz).length()
	if length < STEER_EPSILON:
		return Vector2.ZERO
	return Vector2(dx / length, dz / length)


static func step(x: float, z: float, steer: Vector2) -> Vector2:
	if steer == Vector2.ZERO:
		return Vector2(x, z)
	var nx := clampf(x + steer.x * STEP_DISTANCE, -WORLD_HALF_EXTENT, WORLD_HALF_EXTENT)
	var nz := clampf(z + steer.y * STEP_DISTANCE, -WORLD_HALF_EXTENT, WORLD_HALF_EXTENT)
	if Vector2(nx - x, nz - z).length() < MIN_PATH_LENGTH:
		return Vector2(x, z)
	return Vector2(nx, nz)


static func grounded(height: float, vy: float) -> bool:
	return height <= 0.0 and vy <= 0.0


static func apply_jump_edge(height: float, vy: float, jump: bool) -> float:
	if not jump:
		return vy
	if not grounded(height, vy):
		return vy
	return JUMP_SPEED


static func step_vertical(height: float, vy: float) -> Vector2:
	if grounded(height, vy):
		return Vector2(0.0, 0.0)
	var next_vy := vy - GRAVITY * TICK_DURATION_SEC
	var next_h := height + next_vy * TICK_DURATION_SEC
	if next_h <= 0.0:
		return Vector2(0.0, 0.0)
	return Vector2(next_h, next_vy)
