package game

import (
	"math"

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const SteerEpsilon = 1e-6

const GroundEpsilon = 1e-4

const MaxNavStepHeight = 0.75

const (
	EvMove         = "move"
	EvMoveRejected = "move_rejected"
)

func (p *player) steering() bool {
	return p.steerDX != 0 || p.steerDZ != 0
}

func (w *World) groundYAt(x, z, nearY float64) float64 {
	if w.nav != nil {
		if y, ok := w.nav.HeightAt(x, z, nearY); ok {
			return y
		}
	}
	return w.mapCfg.GroundY
}

func (w *World) grounded(p *player) bool {
	return p.y <= w.groundYAt(p.pos.X, p.pos.Z, p.y)+GroundEpsilon && p.vy <= 0
}

func (p *player) clearSteer() {
	p.steerDX = 0
	p.steerDZ = 0
}

func (w *World) move(p *player, msg mnet.Move, seq mnet.Seq) {
	w.log.Event(w.tick, EvMove, withSeq(gamelog.Fields{
		"player": p.id,
		"dx":     msg.DX,
		"dz":     msg.DZ,
		"jump":   msg.Jump,
	}, seq))

	w.applyJumpEdge(p, msg.Jump)
	w.applyWish(p, msg)
}

func (w *World) applyJumpEdge(p *player, jump bool) {
	if !jump {
		return
	}
	if !w.grounded(p) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonIllegalSample,
			Detail:      "illegal_sample: jump while airborne",
			Re:          mnet.MsgMove,
			Disposition: mnet.ReplyError,
		})
		return
	}
	p.vy = JumpSpeed
}

func (w *World) applyWish(p *player, msg mnet.Move) {
	length := math.Hypot(msg.DX, msg.DZ)
	if length < SteerEpsilon {
		p.clearSteer()
		w.broadcastPose(p)
		return
	}

	if p.casting() && p.castLocomotion == abilitydef.LocomotionRooted {
		p.clearSteer()
		w.broadcastPose(p)
		return
	}

	p.pending = 0
	w.clearPendingTalk(p)
	w.closeDialog(p)
	w.cancelGather(p)
	p.attackApproaching = false
	w.interruptCastOnMove(p, CauseMove)
	p.steerDX = msg.DX / length
	p.steerDZ = msg.DZ / length
}

// steerToward sets sticky wish toward dest for out-of-range interact approach.
func (w *World) steerToward(p *player, dest Point) bool {
	dx := dest.X - p.pos.X
	dz := dest.Z - p.pos.Z
	length := math.Hypot(dx, dz)
	if length < SteerEpsilon {
		p.clearSteer()
		return false
	}
	p.steerDX = dx / length
	p.steerDZ = dz / length
	return true
}

func (w *World) stepSteer(p *player, distance float64) bool {
	from := p.pos
	toX := w.clampWorld(from.X + p.steerDX*distance)
	toZ := w.clampWorld(from.Z + p.steerDZ*distance)
	if w.nav != nil {
		toX, toZ = w.nav.Move(from.X, from.Z, toX, toZ)
	}
	to := Point{X: toX, Z: toZ}
	if math.Hypot(to.X-from.X, to.Z-from.Z) < MinPathLength {
		return false
	}
	wasGrounded := w.grounded(p)
	if wasGrounded {
		newY := w.groundYAt(to.X, to.Z, p.y)
		if w.nav != nil && math.Abs(newY-p.y) > MaxNavStepHeight {
			return false
		}
		p.pos = to
		p.y = newY
		return true
	}
	p.pos = to
	return true
}

func (w *World) stepVertical(p *player, dt float64) bool {
	gy := w.groundYAt(p.pos.X, p.pos.Z, p.y)
	if w.grounded(p) {
		p.y = gy
		p.vy = 0
		return false
	}
	p.vy -= Gravity * dt
	p.y += p.vy * dt
	if p.y <= gy {
		p.y = gy
		p.vy = 0
	}
	return true
}

func (w *World) broadcastPose(p *player) {
	p.lastPoseTick = w.tick
	w.broadcast(mnet.Pose{
		ID:   p.id,
		Tick: w.tick,
		X:    p.pos.X,
		Y:    p.y,
		Z:    p.pos.Z,
	}, nil)
}

func (w *World) clampWorld(v float64) float64 {
	he := w.HalfExtent()
	if v > he {
		return he
	}
	if v < -he {
		return -he
	}
	return v
}
