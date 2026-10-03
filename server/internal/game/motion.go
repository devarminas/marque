package game

import (
	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/motion"
	mnet "github.com/devarminas/marque/server/internal/net"
	"math"
)

type MotionSnapshot struct {
	Player              PlayerHandle
	Tick                uint32
	State               motion.State
	Grounded            bool
	Policy              motion.Policy
	MapID               string
	MapRevision         uint32
	HalfExtent, GroundY float64
	TickIntervalUS      uint32
}

func (p *player) motionState() motion.State {
	return motion.State{X: p.pos.X, Y: p.y, Z: p.pos.Z, VY: p.vy, DX: p.steerDX, DZ: p.steerDZ}
}
func (p *player) setMotion(s motion.State) {
	p.pos = Point{X: s.X, Z: s.Z}
	p.y, p.vy, p.steerDX, p.steerDZ = s.Y, s.VY, s.DX, s.DZ
}
func (w *World) motionMap() motion.Map {
	m := motion.Map{HalfExtent: w.HalfExtent(), GroundY: w.mapCfg.GroundY}
	if w.nav != nil {
		m.Mesh = w.nav
	}
	return m
}
func (w *World) OwnerMotion(h PlayerHandle) (MotionSnapshot, error) {
	p := w.players[mnet.PlayerID(h.Index)]
	if h.Gen != 1 || p == nil || !p.domainOwned || w.tick < 0 || w.tick >= math.MaxUint32 {
		return MotionSnapshot{}, ErrOwner
	}
	policy := motion.Policy{}
	if p.casting() {
		end := uint64(w.tick) + uint64(p.castTotal-p.castProgress)
		if end >= math.MaxUint32 {
			return MotionSnapshot{}, ErrOwner
		}
		policy.EndTick = uint32(end)
		switch p.castLocomotion {
		case abilitydef.LocomotionRooted:
			policy.Mode = motion.Rooted
		case abilitydef.LocomotionInterruptOnMove:
			policy.Mode = motion.InterruptOnMove
		}
	}
	return MotionSnapshot{Player: h, Tick: uint32(w.tick), State: p.motionState(), Grounded: w.grounded(p), Policy: policy, MapID: w.mapCfg.ID, MapRevision: w.motionRevision, HalfExtent: w.HalfExtent(), GroundY: w.mapCfg.GroundY, TickIntervalUS: uint32(TickDuration.Microseconds())}, nil
}
