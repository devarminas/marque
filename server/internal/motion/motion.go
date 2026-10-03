package motion

import "math"

const (
	WalkSpeed     = 3.0
	JumpSpeed     = 5.0
	Gravity       = 20.0
	SteerEpsilon  = 1e-6
	GroundEpsilon = 1e-4
	MinDistance   = 1e-3
	MaxStepHeight = 0.75
	GraceTicks    = 8
)

type State struct{ X, Y, Z, VY, DX, DZ float64 }
type Collision interface {
	HeightAt(x, z, nearY float64) (float64, bool)
	Move(fromX, fromZ, toX, toZ float64) (float64, float64)
}
type Map struct {
	HalfExtent, GroundY float64
	Mesh                Collision
}
type Mode uint8

const (
	Free Mode = iota
	Rooted
	InterruptOnMove
)

type Policy struct {
	Mode    Mode
	EndTick uint32
}
type Input struct {
	DX, DZ float64
	Jump   bool
}

func (m Map) Ground(x, z, nearY float64) float64 {
	if m.Mesh != nil {
		if y, ok := m.Mesh.HeightAt(x, z, nearY); ok {
			return y
		}
	}
	return m.GroundY
}
func Grounded(s State, m Map) bool { return s.Y <= m.Ground(s.X, s.Z, s.Y)+GroundEpsilon && s.VY <= 0 }
func Normalize(dx, dz float64) (float64, float64, bool) {
	length := math.Hypot(dx, dz)
	if length < SteerEpsilon {
		return 0, 0, false
	}
	return dx / length, dz / length, true
}
func Jump(s State, m Map) (State, bool) {
	if !Grounded(s, m) {
		return s, false
	}
	s.VY = JumpSpeed
	return s, true
}
func Apply(s State, m Map, p Policy, in Input, tick uint32) (State, Policy, bool) {
	accepted := true
	if in.Jump {
		s, accepted = Jump(s, m)
	}
	dx, dz, active := Normalize(in.DX, in.DZ)
	if !active || (p.Mode == Rooted && tick < p.EndTick) {
		s.DX, s.DZ = 0, 0
		return s, p, accepted
	}
	if p.Mode == InterruptOnMove && uint64(p.EndTick) > uint64(tick)+GraceTicks {
		p = Policy{}
	}
	s.DX, s.DZ = dx, dz
	return s, p, accepted
}
func Horizontal(s State, m Map, distance float64) (State, bool) {
	x := math.Max(-m.HalfExtent, math.Min(m.HalfExtent, s.X+s.DX*distance))
	z := math.Max(-m.HalfExtent, math.Min(m.HalfExtent, s.Z+s.DZ*distance))
	if m.Mesh != nil {
		x, z = m.Mesh.Move(s.X, s.Z, x, z)
	}
	if math.Hypot(x-s.X, z-s.Z) < MinDistance {
		return s, false
	}
	if Grounded(s, m) {
		y := m.Ground(x, z, s.Y)
		if m.Mesh != nil && math.Abs(y-s.Y) > MaxStepHeight {
			return s, false
		}
		s.Y = y
	}
	s.X, s.Z = x, z
	return s, true
}
func Vertical(s State, m Map, dt float64) (State, bool) {
	gy := m.Ground(s.X, s.Z, s.Y)
	if Grounded(s, m) {
		s.Y, s.VY = gy, 0
		return s, false
	}
	s.VY -= Gravity * dt
	s.Y += s.VY * dt
	if s.Y <= gy {
		s.Y, s.VY = gy, 0
	}
	return s, true
}
func Step(s State, m Map, dt float64) State {
	if s.DX != 0 || s.DZ != 0 {
		s, _ = Horizontal(s, m, WalkSpeed*dt)
	}
	s, _ = Vertical(s, m, dt)
	return s
}
