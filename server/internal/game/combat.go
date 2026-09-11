package game

import (
	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	MaxHP             = 100
	AttackDamage      = 10
	AttackPeriodTicks = 4
	AttackRange       = 1.5
	CauseMoveTo       = "move_to"
	CauseMove         = "move"
	CausePickup       = "pickup"
	CauseGather       = "gather"
	CauseReplaced     = "replaced"
	CauseAttackerDied = "attacker_died"
)

func (p *player) dead() bool { return p.hp == 0 }

func (p *player) wireState() mnet.PlayerState {
	return mnet.PlayerState{
		ID:      p.id,
		X:       p.pos.X,
		Y:       p.y,
		Z:       p.pos.Z,
		HP:      p.hp,
		MaxHP:   MaxHP,
		Mana:    p.mana,
		MaxMana: MaxMana,
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
	if !w.classCombatGate(p) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNeedsClass,
			Detail:      "attack requires an active Combat-family class",
			Re:          mnet.MsgAttack,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if n, ok := w.npcs[msg.Player]; ok {
		if n.faction != FactionHostile {
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonWrongTarget,
				Detail:      "target is not hostile",
				Re:          mnet.MsgAttack,
				Disposition: mnet.ReplyError,
			})
			return
		}
		if n.dead() {
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonTargetDead,
				Detail:      "that target is dead",
				Re:          mnet.MsgAttack,
				Disposition: mnet.ReplyError,
			})
			return
		}
		w.beginAttack(p, n.id, n.pos, seq)
		return
	}
	if _, live := w.players[msg.Player]; live {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "player vs player is disabled",
			Re:          mnet.MsgAttack,
			Disposition: mnet.ReplyError,
		})
		return
	}
	w.refuse(p, &mnet.RejectError{
		Reason:      mnet.ReasonUnknownPlayer,
		Detail:      "no such player",
		Re:          mnet.MsgAttack,
		Disposition: mnet.ReplyError,
	})
}

func (w *World) classCombatGate(p *player) bool {
	if w.classes == nil {
		return false
	}
	res := classdef.ClassOf(w.wornKinds(p), w.classes)
	return res.Class != nil && res.Class.Family == classdef.FamilyCombat
}

func (w *World) beginAttack(p *player, targetID mnet.PlayerID, targetPos Point, seq mnet.Seq) {
	w.cancelAttack(p, CauseReplaced)
	p.pending = 0
	w.clearPendingTalk(p)
	w.cancelGather(p)
	w.cancelAttack(p, CauseReplaced)
	w.cancelCast(p, CauseReplaced)
	p.clearSteer()
	p.attackTarget = targetID
	p.attackProgress = 0
	w.log.Event(w.tick, EvAttack, withSeq(playerTargetFields(p.id, targetID), seq))

	if distanceBetween(p.pos, targetPos) <= AttackRange {
		return
	}
	w.steerToward(p, targetPos)
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
	p.mana = MaxMana
	p.pos = Point{X: w.mapCfg.SpawnX, Z: w.mapCfg.SpawnZ}
	p.y = w.mapCfg.SpawnY
	p.vy = 0
	p.clearSteer()
	w.broadcastPose(p)
	w.broadcastHP(p)
	w.broadcastMana(p)
	w.log.Event(w.tick, EvRespawn, withSeq(gamelog.Fields{"player": p.id}, seq))
}

func (w *World) resolveAttack(p *player) {
	if n, ok := w.npcs[p.attackTarget]; ok {
		w.resolveAttackOnNPC(p, n)
		return
	}
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
		w.steerToward(p, target.pos)
		return
	}
	if p.steering() {
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
		w.kill(target, p.id)
	}
}

func (w *World) resolveAttackOnNPC(p *player, target *npc) {
	if target.dead() {
		w.loseAttack(p)
		return
	}

	dist := distanceBetween(p.pos, target.pos)
	if dist > AttackRange {
		w.steerToward(p, target.pos)
		return
	}
	if p.steering() {
		w.assignHalt(p)
	}

	p.attackProgress++
	if p.attackProgress < AttackPeriodTicks {
		return
	}

	p.attackProgress = 0
	target.hp -= AttackDamage
	if target.kind == KindDummy {
		target.floorPracticeHP()
	} else if target.hp < 0 {
		target.hp = 0
	}
	fields := playerTargetFields(p.id, target.id)
	fields["damage"] = AttackDamage
	fields["target_hp"] = target.hp
	w.log.Event(w.tick, EvAttackHit, fields)
	w.broadcastNPCHP(target)
	if target.dead() {
		w.clearAttacksOn(target.id)
		if target.kind == KindImp {
			w.killImp(target, p.id)
		}
	}
}

func (w *World) kill(victim *player, killer mnet.PlayerID) {
	w.log.Event(w.tick, EvDeath, gamelog.Fields{
		"player": victim.id,
		"killer": killer,
	})
	victim.pending = 0
	w.clearPendingTalk(victim)
	w.closeDialog(victim)
	w.cancelGather(victim)
	w.cancelAttack(victim, CauseAttackerDied)
	w.cancelCast(victim, CauseAttackerDied)
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
