package game

import (
	"math"

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/gamelog"
 "github.com/devarminas/marque/server/internal/motion"
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
	return motion.Grounded(p.motionState(), w.motionMap())
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
	state, accepted := motion.Jump(p.motionState(), w.motionMap())
 if !accepted {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonIllegalSample,
			Detail:      "illegal_sample: jump while airborne",
			Re:          mnet.MsgMove,
			Disposition: mnet.ReplyError,
		})
		return
	}
	p.setMotion(state)
}

func (w *World) applyWish(p *player, msg mnet.Move) {
	dx, dz, active := motion.Normalize(msg.DX, msg.DZ)
	if !active {
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
 p.pickupOrigin=Origin{}
	w.clearPendingTalk(p)
	w.closeDialog(p)
	w.cancelGather(p)
	w.clearPendingUse(p)
	p.attackApproaching = false
	w.interruptCastOnMove(p, CauseMove)
	p.steerDX = dx
	p.steerDZ = dz
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
 state, moved := motion.Horizontal(p.motionState(), w.motionMap(), distance)
 p.setMotion(state)
 return moved
}

func (w *World) stepVertical(p *player, dt float64) bool {
 state, moved := motion.Vertical(p.motionState(), w.motionMap(), dt)
 p.setMotion(state)
 return moved
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
