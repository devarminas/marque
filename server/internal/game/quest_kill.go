package game

import (
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/questdef"
)

const EvQuestKillProgress = "quest_kill_progress"

func (w *World) creditImpKill(killer mnet.PlayerID) {
	w.creditKillQuest(killer, KindImp)
}

func (w *World) creditKillQuest(killer mnet.PlayerID, npcKind string) {
	if w.quests == nil {
		return
	}
	killerP, ok := w.players[killer]
	if !ok {
		return
	}
	for _, p := range w.killQuestCreditRecipients(killerP) {
		w.creditKillQuestPlayer(p, npcKind)
	}
}

func (w *World) killQuestCreditRecipients(killer *player) []*player {
	if killer.partyID == 0 {
		return []*player{killer}
	}
	pt := w.parties[killer.partyID]
	if pt == nil {
		return []*player{killer}
	}
	out := make([]*player, 0, len(pt.members))
	for _, id := range pt.members {
		if p, ok := w.players[id]; ok {
			out = append(out, p)
		}
	}
	return out
}

func (w *World) creditKillQuestPlayer(p *player, npcKind string) {
	for _, id := range w.quests.IDs() {
		q, ok := w.quests.Get(id)
		if !ok || !q.IsKill() || q.Kill.Kind != npcKind {
			continue
		}
		if p.quests[id] != questStatusActive {
			continue
		}
		cur := p.questKillCount(id)
		if cur >= q.Kill.Qty {
			continue
		}
		p.setQuestKillCount(id, cur+1)
		w.log.Event(w.tick, EvQuestKillProgress, gamelog.Fields{
			"player": p.id,
			"quest":  id,
			"count":  cur + 1,
			"need":   q.Kill.Qty,
		})
		w.sendQuestLog(p)
	}
}

func (p *player) questKillCount(id string) int {
	if p.questKillProgress == nil {
		return 0
	}
	return p.questKillProgress[id]
}

func (p *player) setQuestKillCount(id string, n int) {
	if p.questKillProgress == nil {
		p.questKillProgress = make(map[string]int)
	}
	p.questKillProgress[id] = n
}

func (w *World) killQuestReady(p *player, q questdef.Quest) bool {
	if !q.IsKill() {
		return false
	}
	return p.questKillCount(q.ID) >= q.Kill.Qty
}

func (w *World) isQuestTalkNPC(kind string) bool {
	if w.quests == nil {
		return false
	}
	for _, id := range w.quests.IDs() {
		q, ok := w.quests.Get(id)
		if ok && q.TalkNPC == kind {
			return true
		}
	}
	return false
}
