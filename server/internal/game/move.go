package game

import (
	"math"

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const SteerEpsilon = 1e-6

const (
	EvMove         = "move"
	EvMoveRejected = "move_rejected"
)

func (p *player) steering() bool {
	return p.steerDX != 0 || p.steerDZ != 0
}

func (p *player) grounded() bool {
	return p.y <= 0 && p.vy <= 0
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
	if !p.grounded() {
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
		p.remaining = nil
		w.broadcastPose(p)
		return
	}

	if p.casting() && p.castLocomotion == abilitydef.LocomotionRooted {
		p.clearSteer()
		p.remaining = nil
		w.broadcastPose(p)
		return
	}

	p.pending = 0
	w.clearPendingTalk(p)
	w.closeDialog(p)
	w.cancelGather(p)
	w.cancelAttack(p, CauseMove)
	w.interruptCastOnMove(p, CauseMove)
	p.remaining = nil
	p.steerDX = msg.DX / length
	p.steerDZ = msg.DZ / length
}

func (w *World) stepSteer(p *player, distance float64) bool {
	from := p.pos
	to := Point{
		X: clampWorld(from.X + p.steerDX*distance),
		Z: clampWorld(from.Z + p.steerDZ*distance),
	}
	if math.Hypot(to.X-from.X, to.Z-from.Z) < MinPathLength {
		return false
	}
	p.pos = to
	p.remaining = nil
	return true
}

func (w *World) stepVertical(p *player, dt float64) bool {
	if p.grounded() {
		p.y = 0
		p.vy = 0
		return false
	}
	p.vy -= Gravity * dt
	p.y += p.vy * dt
	if p.y <= 0 {
		p.y = 0
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

func clampWorld(v float64) float64 {
	if v > WorldHalfExtent {
		return WorldHalfExtent
	}
	if v < -WorldHalfExtent {
		return -WorldHalfExtent
	}
	return v
}
