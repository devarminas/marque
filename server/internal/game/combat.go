package game

import (
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	MaxHP              = 100
	AttackDamage       = 10
	AttackPeriodTicks  = 4
	AttackRange        = 1.5
	CauseMoveTo        = "move_to"
	CausePickup        = "pickup"
	CauseGather        = "gather"
	CauseReplaced      = "replaced"
	CauseAttackerDied  = "attacker_died"
)

func (p *player) dead() bool { return p.hp == 0 }

func (p *player) wireState() mnet.PlayerState {
	return mnet.PlayerState{
		ID:    p.id,
		X:     p.pos.X,
		Z:     p.pos.Z,
		HP:    p.hp,
		MaxHP: MaxHP,
	}
}

func (w *World) attack(p *player, msg mnet.Attack, seq mnet.Seq) {
	if p.dead() {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonDead,
			Detail:      "you are dead",
			Re:          mnet.MsgAttack,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if msg.Player == p.id {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonSelf,
			Detail:      "cannot attack yourself",
			Re:          mnet.MsgAttack,
			Disposition: mnet.ReplyError,
		})
		return
	}
	target, live := w.players[msg.Player]
	if !live {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownPlayer,
			Detail:      "no such player",
			Re:          mnet.MsgAttack,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if target.dead() {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonTargetDead,
			Detail:      "that player is dead",
			Re:          mnet.MsgAttack,
			Disposition: mnet.ReplyError,
		})
		return
	}

	w.cancelAttack(p, CauseReplaced)
	p.pending = 0
	w.cancelGather(p)
	p.attackTarget = target.id
	p.attackProgress = 0
	w.log.Event(w.tick, EvAttack, withSeq(playerTargetFields(p.id, target.id), seq))

	if distanceBetween(p.pos, target.pos) <= AttackRange {
		return
	}
	points, assign := destinationPath(p, target.pos)
	if !assign {
		return
	}
	w.assignPath(p, points)
}

func (w *World) respawnPlayer(p *player, seq mnet.Seq) {
	if !p.dead() {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNotDead,
			Detail:      "you are not dead",
			Re:          mnet.MsgRespawn,
			Disposition: mnet.ReplyError,
		})
		return
	}

	p.hp = MaxHP
	p.pos = Point{X: spawnX, Z: spawnZ}
	p.remaining = nil
	w.assignPath(p, []Point{p.pos})
	w.broadcastHP(p)
	w.log.Event(w.tick, EvRespawn, withSeq(gamelog.Fields{"player": p.id}, seq))
}

func (w *World) resolveAttack(p *player) {
	target, live := w.players[p.attackTarget]
	if !live {
		w.loseAttack(p)
		return
	}
	if target.dead() {
		w.loseAttack(p)
		return
	}

	dist := distanceBetween(p.pos, target.pos)
	if dist > AttackRange {
		points, assign := destinationPath(p, target.pos)
		if assign {
			w.assignPath(p, points)
		}
		return
	}
	if p.walking() {
		w.assignHalt(p)
	}

	p.attackProgress++
	if p.attackProgress < AttackPeriodTicks {
		return
	}

	p.attackProgress = 0
	target.hp -= AttackDamage
	if target.hp < 0 {
		target.hp = 0
	}
	fields := playerTargetFields(p.id, target.id)
	fields["damage"] = AttackDamage
	fields["target_hp"] = target.hp
	w.log.Event(w.tick, EvAttackHit, fields)
	w.broadcastHP(target)
	if target.hp == 0 {
		w.kill(target, p)
	}
}

func (w *World) kill(victim, killer *player) {
	w.log.Event(w.tick, EvDeath, gamelog.Fields{
		"player": victim.id,
		"killer": killer.id,
	})
	victim.pending = 0
	w.cancelGather(victim)
	w.cancelAttack(victim, CauseAttackerDied)
	w.clearAttacksOn(victim.id)
}

func (w *World) clearAttacksOn(target mnet.PlayerID) {
	for _, p := range w.order {
		if p.attackTarget != target {
			continue
		}
		w.loseAttack(p)
	}
}

func (w *World) cancelAttack(p *player, cause string) {
	if p.attackTarget == 0 {
		return
	}
	w.log.Event(w.tick, EvAttackCancelled, gamelog.Fields{
		"player": p.id,
		"target": p.attackTarget,
		"cause":  cause,
	})
	w.clearAttack(p)
}

func (w *World) loseAttack(p *player) {
	w.log.Event(w.tick, EvAttackLost, playerTargetFields(p.id, p.attackTarget))
	w.clearAttack(p)
}

func (w *World) clearAttack(p *player) {
	p.attackTarget = 0
	p.attackProgress = 0
}

func (w *World) broadcastHP(p *player) {
	w.broadcast(mnet.HP{ID: p.id, HP: p.hp, MaxHP: MaxHP}, nil)
}

func (w *World) refuseIfDead(p *player, re string) bool {
	if !p.dead() {
		return false
	}
	w.refuse(p, &mnet.RejectError{
		Reason:      mnet.ReasonDead,
		Detail:      "you are dead",
		Re:          re,
		Disposition: mnet.ReplyError,
	})
	return true
}

func playerTargetFields(player, target mnet.PlayerID) gamelog.Fields {
	return gamelog.Fields{
		"player": player,
		"target": target,
	}
}
