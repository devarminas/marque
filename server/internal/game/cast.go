package game

import (
	"math"

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	CastGraceTicks = 8

	EvCastBegin     = "cast_begin"
	EvCastCancelled = "cast_cancelled"
)

type castTarget struct {
	id   mnet.PlayerID
	pos  Point
	hp   *int
	npc  *npc
	plyr *player
}

func (t *castTarget) applyHeal(amount int) {
	*t.hp += amount
	maxHP := MaxHP
	if t.npc != nil {
		maxHP = t.npc.maxHP
	}
	if *t.hp > maxHP {
		*t.hp = maxHP
	}
}

func (t *castTarget) applyDamage(amount int) {
	*t.hp -= amount
	if t.npc != nil && t.npc.kind == KindDummy {
		t.npc.floorPracticeHP()
		return
	}
	if *t.hp < 0 {
		*t.hp = 0
	}
}

func (w *World) cast(p *player, msg mnet.Cast, seq mnet.Seq) {
	if w.refuseIfDead(p, mnet.MsgCast) {
		return
	}
	if w.abilities == nil {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownAbility,
			Detail:      "unknown ability",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		})
		return
	}
	ability, ok := w.abilities.Get(msg.Ability)
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownAbility,
			Detail:      "unknown ability",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if isMageAbility(ability.ID) && !w.classMageGate(p) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNeedsClass,
			Detail:      "cast requires an active mage class",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		})
		return
	}

	target, rejection := w.resolveCastTarget(p, ability, msg.Player)
	if rejection != nil {
		w.refuse(p, rejection)
		return
	}

	if target.id != p.id {
		if distanceBetween(p.pos, target.pos) > ability.Range {
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonOutOfRange,
				Detail:      "target out of range",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			})
			return
		}
	}

	cost := int(math.Round(ability.ManaCost))
	if p.mana < cost {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonInsufficientMana,
			Detail:      "not enough mana",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		})
		return
	}

	if ability.CastTicks > 0 {
		w.preparePlayerCast(p, ability)
		w.beginCast(p, ability, target.id, cost, seq)
		return
	}

	if rej := w.applyCast(p, ability, target, cost, seq); rej != nil {
		w.refuse(p, rej)
	}
}

// castAbility is the non-player entry to shared resolve/apply. Player wire
// gates stay on World.cast. NPCs pay no mana until ARM-262.
func (w *World) castAbility(c combatant, abilityID string, targetID mnet.PlayerID) *mnet.RejectError {
	if c.combatDead() {
		return &mnet.RejectError{
			Reason:      mnet.ReasonDead,
			Detail:      "you are dead",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		}
	}
	if w.abilities == nil {
		return &mnet.RejectError{
			Reason:      mnet.ReasonUnknownAbility,
			Detail:      "unknown ability",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		}
	}
	ability, ok := w.abilities.Get(abilityID)
	if !ok {
		return &mnet.RejectError{
			Reason:      mnet.ReasonUnknownAbility,
			Detail:      "unknown ability",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		}
	}
	target, rejection := w.resolveCastTarget(c, ability, targetID)
	if rejection != nil {
		return rejection
	}
	if target.id != c.combatID() && distanceBetween(c.combatPos(), target.pos) > ability.Range {
		return &mnet.RejectError{
			Reason:      mnet.ReasonOutOfRange,
			Detail:      "target out of range",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		}
	}
	cost := 0
	if p := playerCombatant(c); p != nil {
		cost = int(math.Round(ability.ManaCost))
		if p.mana < cost {
			return &mnet.RejectError{
				Reason:      mnet.ReasonInsufficientMana,
				Detail:      "not enough mana",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
	}
	if ability.CastTicks > 0 {
		if p := playerCombatant(c); p != nil {
			w.preparePlayerCast(p, ability)
		} else {
			w.cancelCast(c, CauseReplaced)
		}
		w.beginCast(c, ability, target.id, cost, 0)
		return nil
	}
	return w.applyCast(c, ability, target, cost, 0)
}

func (w *World) preparePlayerCast(p *player, ability abilitydef.Ability) {
	w.cancelCast(p, CauseReplaced)
	p.pending = 0
	w.clearPendingTalk(p)
	w.closeDialog(p)
	w.cancelGather(p)
	w.cancelAttack(p, CauseReplaced)
	if ability.Locomotion != abilitydef.LocomotionMovable {
		p.clearSteer()
	}
}

func (w *World) beginCast(c combatant, ability abilitydef.Ability, targetID mnet.PlayerID, cost int, seq mnet.Seq) {
	rt := c.runtimeCast()
	rt.castAbility = ability.ID
	rt.castLocomotion = ability.Locomotion
	rt.castTarget = targetID
	rt.castProgress = 0
	rt.castTotal = ability.CastTicks
	rt.castCost = cost

	fields := withSeq(gamelog.Fields{
		"ability":   ability.ID,
		"target":    targetID,
		"total":     ability.CastTicks,
		"grace":     CastGraceTicks,
		"mana_cost": cost,
	}, seq)
	mergeCasterFields(fields, c)
	w.log.Event(w.tick, EvCastBegin, fields)
	if p := playerCombatant(c); p != nil {
		w.sendCasting(p)
	}
}

func (w *World) advanceCast(c combatant) {
	rt := c.runtimeCast()
	if !rt.casting() {
		return
	}
	rt.castProgress++
	if p := playerCombatant(c); p != nil {
		w.sendCasting(p)
	}
	if rt.castProgress < rt.castTotal {
		return
	}
	w.finishCast(c)
}

func (w *World) finishCast(c combatant) {
	rt := c.runtimeCast()
	abilityID := rt.castAbility
	targetID := rt.castTarget
	cost := rt.castCost
	rt.clear()

	ability, ok := w.abilities.Get(abilityID)
	if !ok {
		w.sendCastingClearIfPlayer(c)
		return
	}
	target, rejection := w.resolveCastTarget(c, ability, targetID)
	if rejection != nil {
		w.sendCastingClearIfPlayer(c)
		fields := gamelog.Fields{
			"ability": abilityID,
			"target":  targetID,
			"cause":   "target_lost",
		}
		mergeCasterFields(fields, c)
		w.log.Event(w.tick, EvCastCancelled, fields)
		return
	}
	if target.id != c.combatID() && distanceBetween(c.combatPos(), target.pos) > ability.Range {
		w.sendCastingClearIfPlayer(c)
		fields := gamelog.Fields{
			"ability": abilityID,
			"target":  targetID,
			"cause":   "out_of_range",
		}
		mergeCasterFields(fields, c)
		w.log.Event(w.tick, EvCastCancelled, fields)
		return
	}
	_ = w.applyCast(c, ability, target, cost, 0)
	w.sendCastingClearIfPlayer(c)
}

func (w *World) applyCast(c combatant, ability abilitydef.Ability, target *castTarget, cost int, seq mnet.Seq) *mnet.RejectError {
	if p := playerCombatant(c); p != nil {
		if !w.spendMana(p, cost) {
			return &mnet.RejectError{
				Reason:      mnet.ReasonInsufficientMana,
				Detail:      "not enough mana",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
	}

	amount := int(math.Round(ability.Effect.Amount))
	fields := withSeq(gamelog.Fields{
		"ability": ability.ID,
		"target":  target.id,
		"amount":  amount,
		"effect":  ability.Effect.Kind,
	}, seq)
	mergeCasterFields(fields, c)
	w.log.Event(w.tick, EvCast, fields)

	switch ability.Effect.Kind {
	case abilitydef.EffectHeal:
		target.applyHeal(amount)
	case abilitydef.EffectDamage:
		target.applyDamage(amount)
	default:
		if p := playerCombatant(c); p != nil {
			w.refundMana(p, cost)
		}
		return &mnet.RejectError{
			Reason:      mnet.ReasonUnknownAbility,
			Detail:      "unknown effect",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		}
	}

	effectFields := gamelog.Fields{
		"ability":   ability.ID,
		"target":    target.id,
		"effect":    ability.Effect.Kind,
		"amount":    amount,
		"target_hp": *target.hp,
	}
	mergeCasterFields(effectFields, c)
	w.log.Event(w.tick, EvCastEffect, effectFields)
	if target.npc != nil {
		w.broadcastNPCHP(target.npc)
		if ability.Effect.Kind == abilitydef.EffectDamage && target.npc.dead() {
			w.clearAttacksOn(target.npc.id)
			if target.npc.kind == KindImp {
				w.killImp(target.npc, c.combatID())
			}
		}
		return nil
	}
	w.broadcastHP(target.plyr)
	if ability.Effect.Kind == abilitydef.EffectDamage && target.plyr.dead() {
		w.kill(target.plyr, c.combatID())
	}
	return nil
}

func (w *World) interruptCastOnMove(c combatant, cause string) {
	rt := c.runtimeCast()
	if !rt.casting() {
		return
	}
	if rt.castLocomotion != abilitydef.LocomotionInterruptOnMove {
		return
	}
	if rt.castTotal-rt.castProgress <= CastGraceTicks {
		return
	}
	w.cancelCast(c, cause)
}

func (w *World) cancelCast(c combatant, cause string) {
	rt := c.runtimeCast()
	if !rt.casting() {
		return
	}
	fields := gamelog.Fields{
		"ability":  rt.castAbility,
		"target":   rt.castTarget,
		"progress": rt.castProgress,
		"total":    rt.castTotal,
		"cause":    cause,
	}
	mergeCasterFields(fields, c)
	w.log.Event(w.tick, EvCastCancelled, fields)
	rt.clear()
	w.sendCastingClearIfPlayer(c)
}

func (w *World) sendCasting(p *player) {
	w.send(p, mnet.Casting{
		Ability:  p.castAbility,
		Progress: p.castProgress,
		Total:    p.castTotal,
	})
}

func (w *World) sendCastingClear(p *player) {
	w.send(p, mnet.Casting{})
}

func (w *World) sendCastingClearIfPlayer(c combatant) {
	if p := playerCombatant(c); p != nil {
		w.sendCastingClear(p)
	}
}

func mergeCasterFields(fields gamelog.Fields, c combatant) {
	if p := playerCombatant(c); p != nil {
		fields["player"] = p.id
		return
	}
	fields["npc"] = c.combatID()
}

func (w *World) resolveCastTarget(caster combatant, ability abilitydef.Ability, named mnet.PlayerID) (*castTarget, *mnet.RejectError) {
	switch ability.Target {
	case abilitydef.TargetSelf:
		if named != 0 && named != caster.combatID() {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonWrongTarget,
				Detail:      "ability is self-only",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		return combatantCastTarget(caster), nil
	case abilitydef.TargetFriendly:
		if named == 0 {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonNoTarget,
				Detail:      "cast needs a target",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		if named == caster.combatID() {
			return combatantCastTarget(caster), nil
		}
		n, ok := w.npcs[named]
		if !ok {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonWrongTarget,
				Detail:      "target is not friendly",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		if n.faction != FactionFriendly {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonWrongTarget,
				Detail:      "target is not friendly",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		if n.dead() {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonTargetDead,
				Detail:      "that target is dead",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		return npcCastTarget(n), nil
	case abilitydef.TargetHostile:
		if named == 0 {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonNoTarget,
				Detail:      "cast needs a target",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		if named == caster.combatID() {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonWrongTarget,
				Detail:      "target is not hostile",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		if n, ok := w.npcs[named]; ok {
			if n.faction != FactionHostile {
				return nil, &mnet.RejectError{
					Reason:      mnet.ReasonWrongTarget,
					Detail:      "target is not hostile",
					Re:          mnet.MsgCast,
					Disposition: mnet.ReplyError,
				}
			}
			if n.dead() {
				return nil, &mnet.RejectError{
					Reason:      mnet.ReasonTargetDead,
					Detail:      "that target is dead",
					Re:          mnet.MsgCast,
					Disposition: mnet.ReplyError,
				}
			}
			return npcCastTarget(n), nil
		}
		target, live := w.players[named]
		if !live {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonUnknownPlayer,
				Detail:      "no such player",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		if target.dead() {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonTargetDead,
				Detail:      "that player is dead",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		return playerCastTarget(target), nil
	default:
		return nil, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownAbility,
			Detail:      "unknown target rule",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		}
	}
}

func isMageAbility(id string) bool {
	return id == "heal" || id == "fireball"
}

func (w *World) classMageGate(p *player) bool {
	if w.classes == nil {
		return false
	}
	res := classdef.ClassOf(w.wornKinds(p), w.classes)
	return res.Class != nil && res.Class.ID == "mage"
}

func combatantCastTarget(c combatant) *castTarget {
	if p := playerCombatant(c); p != nil {
		return playerCastTarget(p)
	}
	return npcCastTarget(c.(*npc))
}

func playerCastTarget(p *player) *castTarget {
	return &castTarget{id: p.id, pos: p.pos, hp: &p.hp, plyr: p}
}

func npcCastTarget(n *npc) *castTarget {
	return &castTarget{id: n.id, pos: n.pos, hp: &n.hp, npc: n}
}
