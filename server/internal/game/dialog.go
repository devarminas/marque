package game

import (
	"errors"
	"fmt"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/questdef"
)

const (
	TalkRange = PickupRange

	CauseTalk = "talk"

	questStatusActive   questStatus = "active"
	questStatusComplete questStatus = "complete"

	EvTalk                 = "talk"
	EvTalkRejected         = "talk_rejected"
	EvTalkResolved         = "talk_resolved"
	EvDialogOption         = "dialog_option"
	EvDialogOptionRejected = "dialog_option_rejected"
	EvQuestAccepted        = "quest_accepted"
)

type questStatus string

func (w *World) talk(p *player, msg mnet.Talk, seq mnet.Seq) {
	w.log.Event(w.tick, EvTalk, withSeq(playerNPCFields(p.id, msg.NPC), seq))

	n, ok := w.npcs[msg.NPC]
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownPlayer,
			Detail:      "no such npc",
			Re:          mnet.MsgTalk,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if !w.isQuestTalkNPC(n.kind) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "that npc is not talkable",
			Re:          mnet.MsgTalk,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if _, ok := w.questForTalkNPC(n.kind); !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "no quest for that npc",
			Re:          mnet.MsgTalk,
			Disposition: mnet.ReplyError,
		})
		return
	}

	p.pendingTalk = n.id
	p.pending = 0
	w.cancelGather(p)
	w.cancelAttack(p, CauseTalk)
	p.clearSteer()

	points, assign := destinationPath(p, n.pos)
	if !assign {
		return
	}
	w.assignPath(p, points)
}

func (w *World) resolveTalk(p *player) {
	n, ok := w.npcs[p.pendingTalk]
	if !ok || !w.isQuestTalkNPC(n.kind) {
		p.pendingTalk = 0
		return
	}
	if distanceBetween(p.pos, n.pos) > TalkRange {
		return
	}
	q, ok := w.questForTalkNPC(n.kind)
	if !ok {
		p.pendingTalk = 0
		return
	}
	p.pendingTalk = 0
	w.openDialog(p, n, q)
	w.log.Event(w.tick, EvTalkResolved, playerNPCFields(p.id, n.id))
}

func (w *World) dialogOption(p *player, msg mnet.DialogOptionPick, seq mnet.Seq) {
	fields := playerNPCFields(p.id, msg.NPC)
	fields["option"] = msg.Option
	w.log.Event(w.tick, EvDialogOption, withSeq(fields, seq))

	if p.dialogNPC == 0 {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoDialog,
			Detail:      "no open dialog",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if msg.NPC != p.dialogNPC {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "dialog is with a different npc",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}
	n, ok := w.npcs[p.dialogNPC]
	if !ok || !w.isQuestTalkNPC(n.kind) {
		w.closeDialog(p)
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownPlayer,
			Detail:      "no such npc",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if distanceBetween(p.pos, n.pos) > TalkRange {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonOutOfRange,
			Detail:      "too far from npc",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}

	switch msg.Option {
	case mnet.OptionStopTalking:
		w.closeDialog(p)
	case mnet.OptionAcceptQuest:
		w.acceptQuest(p, n)
	case mnet.OptionTurnInQuest:
		w.turnInQuest(p, n)
	default:
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownOption,
			Detail:      fmt.Sprintf("unknown option %q", msg.Option),
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
	}
}

func (w *World) acceptQuest(p *player, n *npc) {
	q, ok := w.questForTalkNPC(n.kind)
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "no quest for that npc",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}
	switch p.quests[q.ID] {
	case questStatusActive:
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonQuestActive,
			Detail:      "quest already accepted",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	case questStatusComplete:
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonQuestComplete,
			Detail:      "quest already complete",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}
	p.quests[q.ID] = questStatusActive
	w.log.Event(w.tick, EvQuestAccepted, gamelog.Fields{
		"player": p.id,
		"quest":  q.ID,
		"npc":    n.id,
	})
	w.closeDialog(p)
	w.sendQuestLog(p)
}

func (w *World) turnInQuest(p *player, n *npc) {
	q, ok := w.questForTalkNPC(n.kind)
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "no quest for that npc",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if !q.IsKill() {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonWrongTarget,
			Detail:      "that quest turns in with give, not talk",
			Re:          mnet.MsgDialogOption,
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
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	default:
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonQuestInactive,
			Detail:      "quest is not active",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if !w.killQuestReady(p, q) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonQuestIncomplete,
			Detail:      "kill objective not complete",
			Re:          mnet.MsgDialogOption,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if err := w.items.GrantInventoryKinds(p.id, q.RewardKinds); err != nil {
		if errors.Is(err, ErrInventoryFull) {
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonInventoryFull,
				Detail:      "inventory is full",
				Re:          mnet.MsgDialogOption,
				Disposition: mnet.ReplyError,
			})
			return
		}
		panic(fmt.Sprintf("game: granting kill quest rewards for player %d: %v", p.id, err))
	}
	p.quests[q.ID] = questStatusComplete
	w.log.Event(w.tick, EvQuestCompleted, gamelog.Fields{
		"player":  p.id,
		"quest":   q.ID,
		"npc":     n.id,
		"rewards": len(q.RewardKinds),
	})
	w.closeDialog(p)
	w.sendInventory(p)
	w.sendQuestLog(p)
}

func (w *World) openDialog(p *player, n *npc, q questdef.Quest) {
	p.dialogNPC = n.id
	w.send(p, w.dialogMessage(p, n, q))
}

func (w *World) closeDialog(p *player) {
	npcID := p.dialogNPC
	p.dialogNPC = 0
	if npcID == 0 {
		return
	}
	w.send(p, mnet.Dialog{
		NPC:     npcID,
		Lines:   []string{},
		Options: []mnet.DialogOption{},
	})
}

func (w *World) dialogMessage(p *player, n *npc, q questdef.Quest) mnet.Dialog {
	status := p.quests[q.ID]
	switch status {
	case questStatusActive:
		if q.IsKill() {
			progress := p.questKillCount(q.ID)
			if w.killQuestReady(p, q) {
				return mnet.Dialog{
					NPC:   n.id,
					Lines: []string{fmt.Sprintf("%s is done. Claim your reward.", q.Name)},
					Options: []mnet.DialogOption{
						{ID: mnet.OptionTurnInQuest},
						{ID: mnet.OptionStopTalking},
					},
				}
			}
			return mnet.Dialog{
				NPC:   n.id,
				Lines: []string{fmt.Sprintf("%s: %s", q.Name, questObjective(q, progress))},
				Options: []mnet.DialogOption{
					{ID: mnet.OptionStopTalking},
				},
			}
		}
		return mnet.Dialog{
			NPC:   n.id,
			Lines: []string{fmt.Sprintf("You are already on %s.", q.Name)},
			Options: []mnet.DialogOption{
				{ID: mnet.OptionStopTalking},
			},
		}
	case questStatusComplete:
		return mnet.Dialog{
			NPC:   n.id,
			Lines: []string{fmt.Sprintf("You already finished %s.", q.Name)},
			Options: []mnet.DialogOption{
				{ID: mnet.OptionStopTalking},
			},
		}
	default:
		return mnet.Dialog{
			NPC:   n.id,
			Lines: []string{fmt.Sprintf("Will you accept %s?", q.Name)},
			Options: []mnet.DialogOption{
				{ID: mnet.OptionAcceptQuest},
				{ID: mnet.OptionStopTalking},
			},
		}
	}
}

func (w *World) questForTalkNPC(kind string) (questdef.Quest, bool) {
	if w.quests == nil {
		return questdef.Quest{}, false
	}
	for _, id := range w.quests.IDs() {
		q, ok := w.quests.Get(id)
		if ok && q.TalkNPC == kind {
			return q, true
		}
	}
	return questdef.Quest{}, false
}

func (w *World) clearPendingTalk(p *player) {
	p.pendingTalk = 0
}

func playerNPCFields(player, npc mnet.PlayerID) gamelog.Fields {
	return gamelog.Fields{"player": player, "npc": npc}
}
