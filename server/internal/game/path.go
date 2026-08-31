package game

import "math"

// Point is a position on the ground plane. The world is 3D but movement is
// not: y is the height of the ground under the point, the client derives it,
// and it never crosses the wire (NOTES.md, "Movement").
type Point struct {
	X float64
	Z float64
}

// StraightLine is M0's pathfinder.
//
// There are no obstacles, so the path from anywhere to anywhere is a segment.
// The polyline protocol does not care where the points came from, so a real
// navmesh replaces this function and nothing else: same return type, same
// callers, no protocol change (NOTES.md, "M0 — movement, no inventory").
//
// The result always begins at from, because the wire contract says points[0] is
// the walker's position at start_tick.
func StraightLine(from, to Point) []Point {
	return []Point{from, to}
}

// Advance walks pos up to dist world units along remaining, and returns the new
// position together with the waypoints still ahead of it.
//
// An empty remaining means the walk is over. dist must not be negative;
// movement along a path is monotonic, and reversing would leave the walker off
// the polyline the client is drawing.
func Advance(pos Point, remaining []Point, dist float64) (Point, []Point) {
	if dist < 0 {
		panic("game: Advance with negative distance")
	}
	for dist > 0 && len(remaining) > 0 {
		target := remaining[0]
		dx, dz := target.X-pos.X, target.Z-pos.Z
		segment := math.Hypot(dx, dz)
		if segment <= dist {
			// Reaching a waypoint exactly, rather than interpolating to within
			// a rounding error of it, keeps a long walk from accumulating drift
			// across its corners.
			pos = target
			remaining = remaining[1:]
			dist -= segment
			continue
		}
		step := dist / segment
		pos = Point{X: pos.X + dx*step, Z: pos.Z + dz*step}
		dist = 0
	}
	return pos, remaining
}
