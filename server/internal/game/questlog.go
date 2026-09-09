package game

import (
	"fmt"
	"sort"

	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/questdef"
)

func (w *World) sendQuestLog(p *player) {
	w.send(p, w.questLogMessage(p))
}

func (w *World) questLogMessage(p *player) mnet.QuestLog {
	ids := make([]string, 0, len(p.quests))
	for id := range p.quests {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	quests := make([]mnet.QuestLogEntry, 0, len(ids))
	for _, id := range ids {
		entry := mnet.QuestLogEntry{
			ID:     id,
			Status: string(p.quests[id]),
		}
		if w.quests != nil {
			if q, ok := w.quests.Get(id); ok {
				entry.Title = q.Name
				entry.Objective = questObjective(q, p.questKillCount(id))
			}
		}
		quests = append(quests, entry)
	}
	return mnet.QuestLog{Quests: quests}
}

func questObjective(q questdef.Quest, killProgress int) string {
	if q.IsKill() {
		if killProgress > q.Kill.Qty {
			killProgress = q.Kill.Qty
		}
		return fmt.Sprintf("Slay %d %ss (%d/%d)", q.Kill.Qty, q.Kill.Kind, killProgress, q.Kill.Qty)
	}
	return fmt.Sprintf("Deliver %d %s", q.Deliver.Qty, q.Deliver.Kind)
}
