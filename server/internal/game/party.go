package game

import (
	"slices"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const PartySize = 4

const (
	EvPartyInvite          = "party_invite"
	EvPartyInviteRejected  = "party_invite_rejected"
	EvPartyInvited         = "party_invited"
	EvPartyAccept          = "party_accept"
	EvPartyAcceptRejected  = "party_accept_rejected"
	EvPartyDecline         = "party_decline"
	EvPartyDeclineRejected = "party_decline_rejected"
	EvPartyLeave           = "party_leave"
	EvPartyLeaveRejected   = "party_leave_rejected"
	EvPartyKick            = "party_kick"
	EvPartyKickRejected    = "party_kick_rejected"
	EvPartyJoined          = "party_joined"
	EvPartyLeft            = "party_left"
	EvPartyKicked          = "party_kicked"
	EvPartyLeader          = "party_leader"
	EvPartyDisbanded       = "party_disbanded"
)

type party struct {
	id      mnet.PartyID
	leader  mnet.PlayerID
	members []mnet.PlayerID
}

func (w *World) partyInvite(p *player, msg mnet.PartyInvite, seq mnet.Seq) {
	w.log.Event(w.tick, EvPartyInvite, withSeq(gamelog.Fields{
		"player": p.id,
		"target": msg.Player,
	}, seq))

	if msg.Player == p.id {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonSelf,
			Detail:      "cannot invite yourself",
			Re:          mnet.MsgPartyInvite,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if _, isNPC := w.npcs[msg.Player]; isNPC {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "cannot invite an npc",
			Re:          mnet.MsgPartyInvite,
			Disposition: mnet.ReplyError,
		})
		return
	}
	target, ok := w.players[msg.Player]
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownPlayer,
			Detail:      "no such player",
			Re:          mnet.MsgPartyInvite,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if target.partyID != 0 {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonAlreadyInParty,
			Detail:      "target is already in a party",
			Re:          mnet.MsgPartyInvite,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if target.pendingInviteFrom != 0 {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonDuplicateInvite,
			Detail:      "target already has a pending invite",
			Re:          mnet.MsgPartyInvite,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if p.partyID != 0 {
		pt := w.parties[p.partyID]
		if pt == nil || pt.leader != p.id {
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonNotLeader,
				Detail:      "only the party leader may invite",
				Re:          mnet.MsgPartyInvite,
				Disposition: mnet.ReplyError,
			})
			return
		}
		if len(pt.members) >= PartySize {
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonPartyFull,
				Detail:      "party is full",
				Re:          mnet.MsgPartyInvite,
				Disposition: mnet.ReplyError,
			})
			return
		}
	}

	target.pendingInviteFrom = p.id
	w.send(target, mnet.PartyInviteNotice{From: p.id})
	w.log.Event(w.tick, EvPartyInvited, gamelog.Fields{
		"player": p.id,
		"target": target.id,
	})
}

func (w *World) partyAccept(p *player, _ mnet.PartyAccept, seq mnet.Seq) {
	w.log.Event(w.tick, EvPartyAccept, withSeq(gamelog.Fields{"player": p.id}, seq))

	fromID := p.pendingInviteFrom
	if fromID == 0 {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoInvite,
			Detail:      "no pending invite",
			Re:          mnet.MsgPartyAccept,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if p.partyID != 0 {
		w.clearPendingInvite(p)
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonAlreadyInParty,
			Detail:      "already in a party",
			Re:          mnet.MsgPartyAccept,
			Disposition: mnet.ReplyError,
		})
		return
	}
	inviter, ok := w.players[fromID]
	if !ok {
		w.clearPendingInvite(p)
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownPlayer,
			Detail:      "inviter is gone",
			Re:          mnet.MsgPartyAccept,
			Disposition: mnet.ReplyError,
		})
		return
	}

	var pt *party
	if inviter.partyID == 0 {
		w.nextPartyID++
		pt = &party{
			id:      w.nextPartyID,
			leader:  inviter.id,
			members: []mnet.PlayerID{inviter.id, p.id},
		}
		w.parties[pt.id] = pt
		inviter.partyID = pt.id
		p.partyID = pt.id
	} else {
		pt = w.parties[inviter.partyID]
		if pt == nil || pt.leader != inviter.id {
			w.clearPendingInvite(p)
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonNotLeader,
				Detail:      "inviter is no longer party leader",
				Re:          mnet.MsgPartyAccept,
				Disposition: mnet.ReplyError,
			})
			return
		}
		if len(pt.members) >= PartySize {
			w.clearPendingInvite(p)
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonPartyFull,
				Detail:      "party is full",
				Re:          mnet.MsgPartyAccept,
				Disposition: mnet.ReplyError,
			})
			return
		}
		pt.members = append(pt.members, p.id)
		p.partyID = pt.id
	}

	w.clearPendingInvite(p)
	w.log.Event(w.tick, EvPartyJoined, partyFields(pt, p.id))
	w.restatedParty(pt)
}

func (w *World) partyDecline(p *player, _ mnet.PartyDecline, seq mnet.Seq) {
	w.log.Event(w.tick, EvPartyDecline, withSeq(gamelog.Fields{"player": p.id}, seq))

	if p.pendingInviteFrom == 0 {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoInvite,
			Detail:      "no pending invite",
			Re:          mnet.MsgPartyDecline,
			Disposition: mnet.ReplyError,
		})
		return
	}
	w.clearPendingInvite(p)
}

func (w *World) partyLeave(p *player, _ mnet.PartyLeave, seq mnet.Seq) {
	w.log.Event(w.tick, EvPartyLeave, withSeq(gamelog.Fields{"player": p.id}, seq))

	if p.partyID == 0 {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNotInParty,
			Detail:      "not in a party",
			Re:          mnet.MsgPartyLeave,
			Disposition: mnet.ReplyError,
		})
		return
	}
	w.removeFromParty(p, EvPartyLeft)
}

func (w *World) partyKick(p *player, msg mnet.PartyKick, seq mnet.Seq) {
	w.log.Event(w.tick, EvPartyKick, withSeq(gamelog.Fields{
		"player": p.id,
		"target": msg.Player,
	}, seq))

	if msg.Player == p.id {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonSelf,
			Detail:      "cannot kick yourself; leave instead",
			Re:          mnet.MsgPartyKick,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if p.partyID == 0 {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNotInParty,
			Detail:      "not in a party",
			Re:          mnet.MsgPartyKick,
			Disposition: mnet.ReplyError,
		})
		return
	}
	pt := w.parties[p.partyID]
	if pt == nil || pt.leader != p.id {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNotLeader,
			Detail:      "only the party leader may kick",
			Re:          mnet.MsgPartyKick,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if _, isNPC := w.npcs[msg.Player]; isNPC {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "cannot kick an npc",
			Re:          mnet.MsgPartyKick,
			Disposition: mnet.ReplyError,
		})
		return
	}
	target, ok := w.players[msg.Player]
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownPlayer,
			Detail:      "no such player",
			Re:          mnet.MsgPartyKick,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if target.partyID == 0 {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNotInParty,
			Detail:      "target is not in a party",
			Re:          mnet.MsgPartyKick,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if target.partyID != p.partyID {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNotSameParty,
			Detail:      "target is not in your party",
			Re:          mnet.MsgPartyKick,
			Disposition: mnet.ReplyError,
		})
		return
	}
	w.removeFromParty(target, EvPartyKicked)
}

func (w *World) removeFromParty(p *player, leaveEv string) {
	pt := w.parties[p.partyID]
	if pt == nil {
		p.partyID = 0
		w.send(p, emptyParty())
		return
	}

	wasLeader := pt.leader == p.id
	pt.members = slices.DeleteFunc(pt.members, func(id mnet.PlayerID) bool { return id == p.id })
	p.partyID = 0

	fields := gamelog.Fields{"party": pt.id, "player": p.id}
	w.log.Event(w.tick, leaveEv, fields)

	if len(pt.members) == 0 {
		delete(w.parties, pt.id)
		w.clearInvitesFrom(p.id)
		w.log.Event(w.tick, EvPartyDisbanded, gamelog.Fields{"party": pt.id})
		w.send(p, emptyParty())
		return
	}

	if wasLeader {
		from := pt.leader
		pt.leader = pt.members[0]
		w.clearInvitesFrom(from)
		w.log.Event(w.tick, EvPartyLeader, gamelog.Fields{
			"party":  pt.id,
			"leader": pt.leader,
			"from":   from,
		})
	}

	w.send(p, emptyParty())
	w.restatedParty(pt)
}

func (w *World) clearPendingInvite(p *player) {
	if p.pendingInviteFrom == 0 {
		return
	}
	p.pendingInviteFrom = 0
	w.send(p, mnet.PartyInviteNotice{From: 0})
}

func (w *World) clearInvitesFrom(inviter mnet.PlayerID) {
	for _, other := range w.order {
		if other.pendingInviteFrom == inviter {
			w.clearPendingInvite(other)
		}
	}
}

func (w *World) restatedParty(pt *party) {
	msg := partyMessage(pt)
	for _, id := range pt.members {
		if member, ok := w.players[id]; ok {
			w.send(member, msg)
		}
	}
}

func (w *World) sendPartyCatchUp(p *player) {
	if p.partyID != 0 {
		if pt := w.parties[p.partyID]; pt != nil {
			w.send(p, partyMessage(pt))
		}
	}
	if p.pendingInviteFrom != 0 {
		w.send(p, mnet.PartyInviteNotice{From: p.pendingInviteFrom})
	}
}

func partyMessage(pt *party) mnet.Party {
	members := make([]mnet.PlayerID, len(pt.members))
	copy(members, pt.members)
	return mnet.Party{ID: pt.id, Leader: pt.leader, Members: members}
}

func emptyParty() mnet.Party {
	return mnet.Party{ID: 0, Leader: 0, Members: []mnet.PlayerID{}}
}

func partyFields(pt *party, joined mnet.PlayerID) gamelog.Fields {
	members := make([]mnet.PlayerID, len(pt.members))
	copy(members, pt.members)
	return gamelog.Fields{
		"party":   pt.id,
		"player":  joined,
		"leader":  pt.leader,
		"members": members,
	}
}
