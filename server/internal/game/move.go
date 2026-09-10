package game

import (
	"math"

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

func (p *player) clearSteer() {
	p.steerDX = 0
	p.steerDZ = 0
}

func (w *World) move(p *player, msg mnet.Move, seq mnet.Seq) {
	w.log.Event(w.tick, EvMove, withSeq(gamelog.Fields{
		"player": p.id,
		"dx":     msg.DX,
		"dz":     msg.DZ,
	}, seq))

	length := math.Hypot(msg.DX, msg.DZ)
	if length < SteerEpsilon {
		p.clearSteer()
		p.remaining = nil
		w.assignPath(p, []Point{p.pos})
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

func (w *World) stepSteer(p *player, distance float64) {
	from := p.pos
	to := Point{
		X: clampWorld(from.X + p.steerDX*distance),
		Z: clampWorld(from.Z + p.steerDZ*distance),
	}
	if math.Hypot(to.X-from.X, to.Z-from.Z) < MinPathLength {
		return
	}
	p.pos = to
	p.remaining = nil
	w.assignPath(p, []Point{from, to})
	p.remaining = nil
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
