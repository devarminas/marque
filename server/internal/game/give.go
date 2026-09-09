package game

import (
	"errors"
	"fmt"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	GiveRange = TalkRange

	EvGive             = "give"
	EvGiveRejected     = "give_rejected"
	EvQuestCompleted   = "quest_completed"
)

func (w *World) give(p *player, msg mnet.Give, seq mnet.Seq) {
	fields := playerNPCFields(p.id, msg.NPC)
	fields["slot"] = msg.Slot
	w.log.Event(w.tick, EvGive, withSeq(fields, seq))

	n, ok := w.npcs[msg.NPC]
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownPlayer,
			Detail:      "no such npc",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if !w.isQuestTalkNPC(n.kind) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "that npc does not take quest turn-ins",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	}
	q, ok := w.questForTalkNPC(n.kind)
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "no quest for that npc",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if distanceBetween(p.pos, n.pos) > GiveRange {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonOutOfRange,
			Detail:      "too far from npc",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
			return
	}
	if !q.IsDeliver() {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "that quest turns in with talk, not give",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	}

	switch p.quests[q.ID] {
	case questStatusActive:
	case questStatusComplete:
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonQuestComplete,
			Detail:      "quest already complete",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	default:
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonQuestInactive,
			Detail:      "quest is not active",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	}

	done, err := w.items.DeliverInventorySlot(p.id, msg.Slot, q.Deliver.Kind, q.RewardKinds)
	switch {
	case errors.Is(err, ErrNoSuchSlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoSuchSlot,
			Detail:      fmt.Sprintf("no such slot: %d is outside 0 to %d", msg.Slot, InventorySize-1),
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	case errors.Is(err, ErrEmptySlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonEmptySlot,
			Detail:      "that slot is empty",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	case errors.Is(err, ErrWrongKind):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongItem,
			Detail:      "that is not the quest item",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	case errors.Is(err, ErrInventoryFull):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonInventoryFull,
			Detail:      "inventory is full",
			Re:          mnet.MsgGive,
			Disposition: mnet.ReplyError,
		})
		return
	case err != nil:
		panic(fmt.Sprintf("game: delivering slot %d for player %d: %v", msg.Slot, p.id, err))
	}

	p.quests[q.ID] = questStatusComplete
	w.log.Event(w.tick, EvQuestCompleted, gamelog.Fields{
		"player":  p.id,
		"quest":   q.ID,
		"npc":     n.id,
		"slot":    done.From,
		"consume": done.Consume,
		"rewards": len(done.Rewards),
	})
	w.closeDialog(p)
	w.sendInventory(p)
	w.sendQuestLog(p)
}
