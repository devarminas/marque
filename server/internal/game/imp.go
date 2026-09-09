package game

import (
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func (w *World) stepNPCs(distance float64) {
	for _, id := range append([]mnet.PlayerID(nil), w.npcOrder...) {
		n := w.npcs[id]
		if n == nil || !n.mobile() || n.dead() {
			continue
		}
		w.stepImp(n, distance)
	}
}

func (w *World) stepImp(n *npc, distance float64) {
	if len(n.remaining) > 0 {
		n.pos, n.remaining = Advance(n.pos, n.remaining, distance)
	}

	switch n.phase {
	case phaseReturn:
		w.stepImpReturn(n)
	case phaseCombat:
		w.stepImpCombat(n)
	default:
		if target := w.firstLivingPlayerInRange(n.pos, ImpThreatRange); target != nil {
			w.beginImpAggro(n, target)
			return
		}
		w.stepImpPatrol(n)
	}
}

func (w *World) stepImpReturn(n *npc) {
	if distanceBetween(n.pos, n.home) <= MinPathLength {
		n.pos = n.home
		n.remaining = nil
		n.phase = phaseIdle
		n.patrolOut = false
		return
	}
	if len(n.remaining) == 0 {
		w.assignNPCPath(n, n.home)
	}
}

func (w *World) stepImpCombat(n *npc) {
	if distanceBetween(n.pos, n.home) > ImpLeashRange {
		w.beginImpLeash(n)
		return
	}
	target, live := w.players[n.target]
	if !live || target.dead() {
		w.beginImpLeash(n)
		return
	}

	dist := distanceBetween(n.pos, target.pos)
	if dist > AttackRange {
		n.attackProgress = 0
		w.assignNPCPath(n, target.pos)
		return
	}
	if len(n.remaining) > 0 {
		w.assignNPCHalt(n)
	}

	n.attackProgress++
	if n.attackProgress < AttackPeriodTicks {
		return
	}
	n.attackProgress = 0

	target.hp -= ImpDamage
	if target.hp < 0 {
		target.hp = 0
	}
	fields := gamelog.Fields{
		"npc":       n.id,
		"target":    target.id,
		"damage":    ImpDamage,
		"target_hp": target.hp,
	}
	w.log.Event(w.tick, EvAttackHit, fields)
	w.broadcastHP(target)
	if target.dead() {
		w.kill(target, n.id)
		w.beginImpLeash(n)
	}
}

func (w *World) beginImpAggro(n *npc, target *player) {
	n.phase = phaseCombat
	n.target = target.id
	n.attackProgress = 0
	w.log.Event(w.tick, EvNpcAggro, gamelog.Fields{
		"npc":    n.id,
		"kind":   n.kind,
		"target": target.id,
	})
	if distanceBetween(n.pos, target.pos) > AttackRange {
		w.assignNPCPath(n, target.pos)
	}
}

func (w *World) beginImpLeash(n *npc) {
	if n.phase == phaseReturn && n.target == 0 {
		return
	}
	prev := n.target
	n.phase = phaseReturn
	n.target = 0
	n.attackProgress = 0
	w.log.Event(w.tick, EvNpcLeash, gamelog.Fields{
		"npc":    n.id,
		"kind":   n.kind,
		"target": prev,
		"x":      n.pos.X,
		"z":      n.pos.Z,
	})
	w.assignNPCPath(n, n.home)
}

func (w *World) stepImpPatrol(n *npc) {
	if len(n.remaining) > 0 {
		return
	}
	dest := n.home
	if !n.patrolOut {
		dest = Point{X: n.home.X + ImpPatrolRadius, Z: n.home.Z}
	}
	n.patrolOut = !n.patrolOut
	if distanceBetween(n.pos, dest) < MinPathLength {
		return
	}
	w.assignNPCPath(n, dest)
}

func (w *World) firstLivingPlayerInRange(origin Point, radius float64) *player {
	for _, p := range w.order {
		if p.dead() {
			continue
		}
		if distanceBetween(origin, p.pos) <= radius {
			return p
		}
	}
	return nil
}

func (w *World) assignNPCPath(n *npc, dest Point) {
	points, assign := npcDestinationPath(n, dest)
	if !assign {
		return
	}
	n.remaining = points[1:]
	out := mnet.Path{
		ID:        n.id,
		StartTick: w.tick,
		Points:    wirePoints(points),
		Speed:     WalkSpeed,
	}
	fields := pathLogFields(out)
	delete(fields, "player")
	fields["npc"] = n.id
	w.log.Event(w.tick, EvPathAssigned, fields)
	w.broadcast(out, nil)
}

func (w *World) assignNPCHalt(n *npc) {
	w.assignNPCPath(n, n.pos)
}

func npcDestinationPath(n *npc, dest Point) (points []Point, assign bool) {
	line := StraightLine(n.pos, dest)
	if length(line) >= MinPathLength {
		return line, true
	}
	if len(n.remaining) > 0 {
		return []Point{n.pos}, true
	}
	return nil, false
}

func (w *World) killImp(n *npc, killer mnet.PlayerID) {
	n.phase = phaseIdle
	n.target = 0
	n.attackProgress = 0
	n.remaining = nil
	fields := gamelog.Fields{
		"npc":    n.id,
		"kind":   n.kind,
		"killer": killer,
	}
	if n.camp != "" {
		fields["camp"] = n.camp
	}
	w.log.Event(w.tick, EvDeath, fields)
	w.noteCampDespawn(n)
	w.creditImpKill(killer)
	if killerP, ok := w.players[killer]; ok {
		w.grantClassSkillXP(killerP, SkillXPKill)
	}
	w.despawnNPC(n)
}
