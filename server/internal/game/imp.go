package game

import (
	"math"

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
	arrived := false
	if len(n.remaining) > 0 {
		n.pos, n.remaining = Advance(n.pos, n.remaining, distance)
		if len(n.remaining) == 0 {
			arrived = true
		}
	}

	walking := len(n.remaining) > 0
	switch n.phase {
	case phaseReturn:
		if w.stepImpReturn(n) {
			arrived = true
		}
	case phaseAggro:
		w.stepImpAggro(n)
	case phaseApproach:
		w.stepImpApproach(n)
	case phaseAttack:
		w.stepImpAttack(n)
	case phaseThink:
		w.stepImpThink(n)
	case phaseKite:
		w.stepImpKite(n, arrived)
	default:
		if target := w.nearestLivingPlayerInRange(n.pos, ImpThreatRange); target != nil {
			w.beginImpAggro(n, target)
			if arrived {
				w.logNPCArrived(n)
			}
			return
		}
		w.stepImpPatrol(n)
	}
	if walking && len(n.remaining) == 0 {
		arrived = true
	}
	if arrived {
		w.logNPCArrived(n)
	}
}

func (w *World) logNPCArrived(n *npc) {
	w.log.Event(w.tick, EvArrived, gamelog.Fields{
		"npc": n.id,
		"x":   n.pos.X,
		"z":   n.pos.Z,
	})
}

func (w *World) stepImpReturn(n *npc) (snapped bool) {
	if distanceBetween(n.pos, n.home) <= MinPathLength {
		n.pos = n.home
		n.remaining = nil
		w.resetImpCombat(n)
		n.phase = phasePatrol
		n.patrolOut = false
		return true
	}
	if len(n.remaining) == 0 {
		w.assignNPCPath(n, n.home)
	}
	return false
}

func (w *World) stepImpAggro(n *npc) {
	if w.impMustLeash(n) {
		return
	}
	n.phase = phaseApproach
	w.stepImpApproach(n)
}

func (w *World) stepImpApproach(n *npc) {
	if w.impMustLeash(n) {
		return
	}
	target := w.players[n.attackTarget]
	dist := distanceBetween(n.pos, target.pos)
	if dist <= AttackRange {
		if len(n.remaining) > 0 {
			w.assignNPCHalt(n)
		}
		n.phase = phaseAttack
		n.attackProgress = 0
		w.stepImpAttack(n)
		return
	}
	w.assignNPCPath(n, target.pos)
}

func (w *World) stepImpAttack(n *npc) {
	if w.impMustLeash(n) {
		return
	}
	target := w.players[n.attackTarget]
	dist := distanceBetween(n.pos, target.pos)
	if dist > AttackRange {
		n.attackProgress = 0
		n.phase = phaseApproach
		w.assignNPCPath(n, target.pos)
		return
	}
	if len(n.remaining) > 0 {
		w.assignNPCHalt(n)
	}

	n.attackProgress++
	if n.attackProgress < w.npcAttackPeriod(n) {
		return
	}
	n.attackProgress = 0

	target.hp -= ImpDamage
	if target.hp < 0 {
		target.hp = 0
	}
	w.markCombat(target)
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
		return
	}
	n.phase = phaseThink
	n.thinkProgress = 0
}

func (w *World) stepImpThink(n *npc) {
	if w.impMustLeash(n) {
		return
	}
	n.thinkProgress++
	if n.thinkProgress < ImpThinkTicks {
		return
	}
	n.thinkProgress = 0
	n.thinkCount++

	target := w.players[n.attackTarget]
	if n.thinkCount%ImpKiteEvery == 0 {
		n.phase = phaseKite
		w.beginImpKite(n, target)
		return
	}
	if distanceBetween(n.pos, target.pos) > AttackRange {
		n.phase = phaseApproach
		w.assignNPCPath(n, target.pos)
		return
	}
	n.phase = phaseAttack
	n.attackProgress = 0
}

func (w *World) beginImpKite(n *npc, target *player) {
	away := kitePoint(n.pos, target.pos, n.home, ImpKiteDistance)
	if distanceBetween(n.pos, away) < MinPathLength {
		n.phase = phaseThink
		n.thinkProgress = 0
		return
	}
	w.assignNPCPath(n, away)
}

func (w *World) stepImpKite(n *npc, arrived bool) {
	if w.impMustLeash(n) {
		return
	}
	if !arrived && len(n.remaining) > 0 {
		return
	}
	n.phase = phaseThink
	n.thinkProgress = 0
}

func kitePoint(from, threat, home Point, distance float64) Point {
	dx := from.X - threat.X
	dz := from.Z - threat.Z
	mag := math.Hypot(dx, dz)
	if mag < MinPathLength {
		dx = from.X - home.X
		dz = from.Z - home.Z
		mag = math.Hypot(dx, dz)
		if mag < MinPathLength {
			dx, dz, mag = 1, 0, 1
		}
	}
	dest := Point{
		X: from.X + dx/mag*distance,
		Z: from.Z + dz/mag*distance,
	}
	if distanceBetween(home, dest) > ImpLeashRange {
		scale := (ImpLeashRange - MinPathLength) / distanceBetween(home, dest)
		dest = Point{
			X: home.X + (dest.X-home.X)*scale,
			Z: home.Z + (dest.Z-home.Z)*scale,
		}
	}
	return dest
}

func (w *World) impMustLeash(n *npc) bool {
	if distanceBetween(n.pos, n.home) > ImpLeashRange {
		w.beginImpLeash(n)
		return true
	}
	target, live := w.players[n.attackTarget]
	if !live || target.dead() {
		w.beginImpLeash(n)
		return true
	}
	return false
}

func (w *World) beginImpAggro(n *npc, target *player) {
	n.phase = phaseAggro
	n.attackTarget = target.id
	w.resetImpCombat(n)
	w.markCombat(target)
	w.log.Event(w.tick, EvNpcAggro, gamelog.Fields{
		"npc":    n.id,
		"kind":   n.kind,
		"target": target.id,
	})
	w.stepImpAggro(n)
}

func (w *World) beginImpLeash(n *npc) {
	if n.phase == phaseReturn && n.attackTarget == 0 {
		return
	}
	prev := n.attackTarget
	n.phase = phaseReturn
	n.attackTarget = 0
	w.resetImpCombat(n)
	w.log.Event(w.tick, EvNpcLeash, gamelog.Fields{
		"npc":    n.id,
		"kind":   n.kind,
		"target": prev,
		"x":      n.pos.X,
		"z":      n.pos.Z,
	})
	w.assignNPCPath(n, n.home)
}

func (w *World) resetImpCombat(n *npc) {
	n.attackProgress = 0
	n.thinkProgress = 0
	n.thinkCount = 0
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

func (w *World) nearestLivingPlayerInRange(origin Point, radius float64) *player {
	var best *player
	bestDist := 0.0
	for _, p := range w.order {
		if p.dead() {
			continue
		}
		d := distanceBetween(origin, p.pos)
		if d > radius {
			continue
		}
		if best == nil || d < bestDist {
			best = p
			bestDist = d
		}
	}
	return best
}

func (w *World) assignNPCPath(n *npc, dest Point) {
	points, assign := w.npcDestinationPath(n, dest)
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

func (w *World) npcDestinationPath(n *npc, dest Point) (points []Point, assign bool) {
	line := StraightLine(n.pos, dest)
	if w.nav != nil {
		navPath, _ := w.nav.FindPath(n.pos.X, n.pos.Z, dest.X, dest.Z)
		if len(navPath) > 0 {
			line = make([]Point, len(navPath))
			for i, p := range navPath {
				line[i] = Point{X: p.X, Z: p.Z}
			}
		}
	}
	if length(line) >= MinPathLength {
		return line, true
	}
	if len(n.remaining) > 0 {
		return []Point{n.pos}, true
	}
	return nil, false
}

func (w *World) killImp(n *npc, killer mnet.PlayerID) {
	n.phase = phasePatrol
	n.attackTarget = 0
	w.resetImpCombat(n)
	n.remaining = nil
	n.castRuntime.clear()
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
