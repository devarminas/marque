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

func (p *player) casting() bool { return p.castAbility != "" }

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
		w.beginCast(p, ability, target.id, cost, seq)
		return
	}

	w.applyCast(p, ability, target, cost, seq)
}

func (w *World) beginCast(p *player, ability abilitydef.Ability, targetID mnet.PlayerID, cost int, seq mnet.Seq) {
	w.cancelCast(p, CauseReplaced)
	p.pending = 0
	w.clearPendingTalk(p)
	w.closeDialog(p)
	w.cancelGather(p)
	w.cancelAttack(p, CauseReplaced)
	if ability.Locomotion != abilitydef.LocomotionMovable {
		p.clearSteer()
	}
	p.remaining = nil

	p.castAbility = ability.ID
	p.castLocomotion = ability.Locomotion
	p.castTarget = targetID
	p.castProgress = 0
	p.castTotal = ability.CastTicks
	p.castCost = cost

	w.log.Event(w.tick, EvCastBegin, withSeq(gamelog.Fields{
		"player":    p.id,
		"ability":   ability.ID,
		"target":    targetID,
		"total":     ability.CastTicks,
		"grace":     CastGraceTicks,
		"mana_cost": cost,
	}, seq))
	w.sendCasting(p)
}

func (w *World) advanceCast(p *player) {
	if !p.casting() {
		return
	}
	p.castProgress++
	w.sendCasting(p)
	if p.castProgress < p.castTotal {
		return
	}
	w.finishCast(p)
}

func (w *World) finishCast(p *player) {
	abilityID := p.castAbility
	targetID := p.castTarget
	cost := p.castCost
	w.clearCastState(p)

	ability, ok := w.abilities.Get(abilityID)
	if !ok {
		w.sendCastingClear(p)
		return
	}
	target, rejection := w.resolveCastTarget(p, ability, targetID)
	if rejection != nil {
		w.sendCastingClear(p)
		w.log.Event(w.tick, EvCastCancelled, gamelog.Fields{
			"player":  p.id,
			"ability": abilityID,
			"target":  targetID,
			"cause":   "target_lost",
		})
		return
	}
	if target.id != p.id && distanceBetween(p.pos, target.pos) > ability.Range {
		w.sendCastingClear(p)
		w.log.Event(w.tick, EvCastCancelled, gamelog.Fields{
			"player":  p.id,
			"ability": abilityID,
			"target":  targetID,
			"cause":   "out_of_range",
		})
		return
	}
	w.applyCast(p, ability, target, cost, 0)
	w.sendCastingClear(p)
}

func (w *World) applyCast(p *player, ability abilitydef.Ability, target *castTarget, cost int, seq mnet.Seq) {
	if !w.spendMana(p, cost) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonInsufficientMana,
			Detail:      "not enough mana",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		})
		return
	}

	amount := int(math.Round(ability.Effect.Amount))
	fields := withSeq(gamelog.Fields{
		"player":  p.id,
		"ability": ability.ID,
		"target":  target.id,
		"amount":  amount,
		"effect":  ability.Effect.Kind,
	}, seq)
	w.log.Event(w.tick, EvCast, fields)

	switch ability.Effect.Kind {
	case abilitydef.EffectHeal:
		target.applyHeal(amount)
	case abilitydef.EffectDamage:
		target.applyDamage(amount)
	default:
		w.refundMana(p, cost)
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownAbility,
			Detail:      "unknown effect",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		})
		return
	}

	w.log.Event(w.tick, EvCastEffect, gamelog.Fields{
		"player":    p.id,
		"ability":   ability.ID,
		"target":    target.id,
		"effect":    ability.Effect.Kind,
		"amount":    amount,
		"target_hp": *target.hp,
	})
	if target.npc != nil {
		w.broadcastNPCHP(target.npc)
		if ability.Effect.Kind == abilitydef.EffectDamage && target.npc.dead() {
			w.clearAttacksOn(target.npc.id)
			if target.npc.kind == KindImp {
				w.killImp(target.npc, p.id)
			}
		}
		return
	}
	w.broadcastHP(target.plyr)
	if ability.Effect.Kind == abilitydef.EffectDamage && target.plyr.dead() {
		w.kill(target.plyr, p.id)
	}
}

func (w *World) interruptCastOnMove(p *player, cause string) {
	if !p.casting() {
		return
	}
	if p.castLocomotion != abilitydef.LocomotionInterruptOnMove {
		return
	}
	if p.castTotal-p.castProgress <= CastGraceTicks {
		return
	}
	w.cancelCast(p, cause)
}

func (w *World) cancelCast(p *player, cause string) {
	if !p.casting() {
		return
	}
	w.log.Event(w.tick, EvCastCancelled, gamelog.Fields{
		"player":   p.id,
		"ability":  p.castAbility,
		"target":   p.castTarget,
		"progress": p.castProgress,
		"total":    p.castTotal,
		"cause":    cause,
	})
	w.clearCastState(p)
	w.sendCastingClear(p)
}

func (w *World) clearCastState(p *player) {
	p.castAbility = ""
	p.castLocomotion = ""
	p.castTarget = 0
	p.castProgress = 0
	p.castTotal = 0
	p.castCost = 0
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

func (w *World) resolveCastTarget(caster *player, ability abilitydef.Ability, named mnet.PlayerID) (*castTarget, *mnet.RejectError) {
	switch ability.Target {
	case abilitydef.TargetSelf:
		if named != 0 && named != caster.id {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonWrongTarget,
				Detail:      "ability is self-only",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		return playerCastTarget(caster), nil
	case abilitydef.TargetFriendly:
		if named == 0 {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonNoTarget,
				Detail:      "cast needs a target",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		if named == caster.id {
			return playerCastTarget(caster), nil
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
		if named == caster.id {
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

func playerCastTarget(p *player) *castTarget {
	return &castTarget{id: p.id, pos: p.pos, hp: &p.hp, plyr: p}
}

func npcCastTarget(n *npc) *castTarget {
	return &castTarget{id: n.id, pos: n.pos, hp: &n.hp, npc: n}
}
