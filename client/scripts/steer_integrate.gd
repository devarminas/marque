extends RefCounted


const WALK_SPEED := 3.0
const TICK_DURATION_SEC := 0.04
const WORLD_HALF_EXTENT := 128.0
const STEER_EPSILON := 1e-6
const MIN_PATH_LENGTH := 1e-3
const STEP_DISTANCE := WALK_SPEED * TICK_DURATION_SEC
const JUMP_SPEED := 5.0
const GRAVITY := 20.0
const GROUND_EPSILON := 1e-4
const MAX_NAV_STEP_HEIGHT := 0.75


static func wish_to_steer(dx: float, dz: float) -> Vector2:
	var length := Vector2(dx, dz).length()
	if length < STEER_EPSILON:
		return Vector2.ZERO
	return Vector2(dx / length, dz / length)


static func clamp_world(v: float, half_extent: float = WORLD_HALF_EXTENT) -> float:
	return clampf(v, -half_extent, half_extent)


static func step(
	x: float,
	z: float,
	steer: Vector2,
	half_extent: float = WORLD_HALF_EXTENT,
	nav = null,
) -> Vector2:
	if steer == Vector2.ZERO:
		return Vector2(x, z)
	var nx := clamp_world(x + steer.x * STEP_DISTANCE, half_extent)
	var nz := clamp_world(z + steer.y * STEP_DISTANCE, half_extent)
	if nav != null:
		var moved: Vector2 = nav.move(x, z, nx, nz)
		nx = moved.x
		nz = moved.y
	if Vector2(nx - x, nz - z).length() < MIN_PATH_LENGTH:
		return Vector2(x, z)
	return Vector2(nx, nz)


static func grounded(height: float, vy: float, ground_y: float = 0.0) -> bool:
	return height <= ground_y + GROUND_EPSILON and vy <= 0.0


static func apply_jump_edge(
	height: float, vy: float, jump: bool, ground_y: float = 0.0
) -> float:
	if not jump:
		return vy
	if not grounded(height, vy, ground_y):
		return vy
	return JUMP_SPEED


static func step_vertical(height: float, vy: float, ground_y: float = 0.0) -> Vector2:
	if grounded(height, vy, ground_y):
		return Vector2(ground_y, 0.0)
	var next_vy := vy - GRAVITY * TICK_DURATION_SEC
	var next_h := height + next_vy * TICK_DURATION_SEC
	if next_h <= ground_y:
		return Vector2(ground_y, 0.0)
	return Vector2(next_h, next_vy)
