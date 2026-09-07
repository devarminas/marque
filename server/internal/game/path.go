package game

import "math"

type Point struct {
	X float64
	Z float64
}

func StraightLine(from, to Point) []Point {
	return []Point{from, to}
}

func Advance(pos Point, remaining []Point, dist float64) (Point, []Point) {
	if dist < 0 {
		panic("game: Advance with negative distance")
	}
	for dist > 0 && len(remaining) > 0 {
		target := remaining[0]
		dx, dz := target.X-pos.X, target.Z-pos.Z
		segment := math.Hypot(dx, dz)
		if segment <= dist {
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
