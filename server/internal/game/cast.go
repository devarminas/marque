package game

import (
	"math"

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
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
	if *t.hp > MaxHP {
		*t.hp = MaxHP
	}
}

func (t *castTarget) applyDamage(amount int) {
	*t.hp -= amount
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
		}
		return
	}
	w.broadcastHP(target.plyr)
	if ability.Effect.Kind == abilitydef.EffectDamage && target.plyr.dead() {
		w.kill(target.plyr, p)
	}
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
