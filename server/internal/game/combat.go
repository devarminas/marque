package game

import (
	"time"

	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/weapondef"
)

const (
	MaxHP              = 100
	AttackDamage       = 10
	AttackRange        = 1.5
	CombatTimeoutTicks = int64(6 * time.Second / TickDuration)
	CauseMoveTo        = "move_to"
	CauseMove          = "move"
	CausePickup        = "pickup"
	CauseGather        = "gather"
	CauseReplaced      = "replaced"
	CauseAttackerDied  = "attacker_died"
	CauseLeaveCombat   = "leave_combat"
)

func (p *player) dead() bool { return p.hp == 0 }

func (p *player) inCombat(tick int64) bool {
	return p.combatExpiresTick > tick
}

func (w *World) markCombat(p *player) {
	if p.dead() {
		return
	}
	p.combatExpiresTick = w.tick + CombatTimeoutTicks
}

func (p *player) clearCombat() {
	p.combatExpiresTick = 0
}

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

func (w *World) playerWeaponID(p *player) string {
	worn := w.wornKinds(p)
	for _, slot := range []string{string(SlotRightHand), string(SlotLeftHand)} {
		kind := worn[slot]
		if kind == "" || w.weapons == nil {
			continue
		}
		if _, ok := w.weapons.Get(kind); ok {
			return kind
		}
	}
	return weapondef.Unarmed
}

func (w *World) npcWeaponID(n *npc) string {
	if n == nil || n.weapon == "" {
		return weapondef.Unarmed
	}
	return n.weapon
}

func (w *World) attackPeriodTicks(weaponID string) int {
	if w.weapons == nil {
		panic("game: weapons catalog required for auto-attack")
	}
	if period, ok := w.weapons.Period(weaponID); ok {
		return period
	}
	period, ok := w.weapons.Period(weapondef.Unarmed)
	if !ok {
		panic("game: weapons catalog missing unarmed")
	}
	return period
}

func (w *World) playerAttackPeriod(p *player) int {
	return w.attackPeriodTicks(w.playerWeaponID(p))
}

func (w *World) npcAttackPeriod(n *npc) int {
	return w.attackPeriodTicks(w.npcWeaponID(n))
}

func (w *World) beginAttack(p *player, targetID mnet.PlayerID, targetPos Point, seq mnet.Seq) {
	p.pending = 0
	w.clearPendingTalk(p)
	w.cancelGather(p)
	w.cancelAttack(p, CauseReplaced)
	w.cancelCast(p, CauseReplaced)
	p.clearSteer()
	// Expired combat must not poison a fresh sticky arm: stickyAutoAttackAllowed
	// treats a non-zero expires tick as "must still be in combat".
	if p.combatExpiresTick != 0 && !p.inCombat(w.tick) {
		p.clearCombat()
	}
	p.attackTarget = targetID
	p.attackProgress = 0
	p.attackApproaching = false
	w.log.Event(w.tick, EvAttack, withSeq(playerTargetFields(p.id, targetID), seq))

	if distanceBetween(p.pos, targetPos) <= AttackRange {
		return
	}
	p.attackApproaching = true
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
	p.clearCombat()
	w.broadcastPose(p)
	w.broadcastHP(p)
	w.broadcastMana(p)
	w.log.Event(w.tick, EvRespawn, withSeq(gamelog.Fields{"player": p.id}, seq))
}

func (w *World) resolveAttack(p *player) {
	if !w.stickyAutoAttackAllowed(p) {
		w.cancelAttack(p, CauseLeaveCombat)
		return
	}
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
		return
	}
	w.finishAttackApproach(p)

	period := w.playerAttackPeriod(p)
	p.attackProgress++
	if p.attackProgress < period {
		return
	}

	p.attackProgress = 0
	target.hp -= AttackDamage
	if target.hp < 0 {
		target.hp = 0
	}
	w.markCombat(p)
	w.markCombat(target)
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
		return
	}
	w.finishAttackApproach(p)

	period := w.playerAttackPeriod(p)
	p.attackProgress++
	if p.attackProgress < period {
		return
	}

	p.attackProgress = 0
	target.hp -= AttackDamage
	if target.kind == KindDummy {
		target.floorPracticeHP()
	} else if target.hp < 0 {
		target.hp = 0
	}
	w.markCombat(p)
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

func (w *World) stickyAutoAttackAllowed(p *player) bool {
	if p.combatExpiresTick == 0 {
		return true
	}
	return p.inCombat(w.tick)
}

func (w *World) finishAttackApproach(p *player) {
	if !p.attackApproaching {
		return
	}
	p.attackApproaching = false
	if p.steering() {
		w.assignHalt(p)
	}
}

func (w *World) kill(victim *player, killer mnet.PlayerID) {
	w.log.Event(w.tick, EvDeath, gamelog.Fields{
		"player": victim.id,
		"killer": killer,
	})
	victim.pending = 0
	victim.clearCombat()
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
	if cause == CauseLeaveCombat {
		p.clearCombat()
	}
}

func (w *World) loseAttack(p *player) {
	w.log.Event(w.tick, EvAttackLost, playerTargetFields(p.id, p.attackTarget))
	w.clearAttack(p)
}

func (w *World) clearAttack(p *player) {
	p.attackTarget = 0
	p.attackProgress = 0
	p.attackApproaching = false
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
