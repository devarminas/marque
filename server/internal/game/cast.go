package game

import (
	"math"

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

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

	target, rejection := w.resolveCastTarget(p, ability, msg.Player)
	if rejection != nil {
		w.refuse(p, rejection)
		return
	}

	if target != p {
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
		target.hp += amount
		if target.hp > MaxHP {
			target.hp = MaxHP
		}
	case abilitydef.EffectDamage:
		target.hp -= amount
		if target.hp < 0 {
			target.hp = 0
		}
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
		"target_hp": target.hp,
	})
	w.broadcastHP(target)
	if ability.Effect.Kind == abilitydef.EffectDamage && target.hp == 0 && target != p {
		w.kill(target, p)
	}
}

func (w *World) resolveCastTarget(caster *player, ability abilitydef.Ability, named mnet.PlayerID) (*player, *mnet.RejectError) {
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
		return caster, nil
	case abilitydef.TargetFriendly:
		// Until factions exist, only the caster is friendly (heal is self-cast).
		if named == 0 {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonNoTarget,
				Detail:      "cast needs a target",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		if named != caster.id {
			return nil, &mnet.RejectError{
				Reason:      mnet.ReasonWrongTarget,
				Detail:      "target is not friendly",
				Re:          mnet.MsgCast,
				Disposition: mnet.ReplyError,
			}
		}
		return caster, nil
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
		return target, nil
	default:
		return nil, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownAbility,
			Detail:      "unknown target rule",
			Re:          mnet.MsgCast,
			Disposition: mnet.ReplyError,
		}
	}
}
