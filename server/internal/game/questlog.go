package game

import (
	"fmt"

	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/questdef"
)

func (w *World) sendQuestLog(p *player) {
	w.emitOwner(p, w.questLogValue(p))
	w.send(p, w.questLogMessage(p))
}

func (w *World) questLogMessage(p *player) mnet.QuestLog {
	out := mnet.QuestLog{Quests: make([]mnet.QuestLogEntry, 0, len(p.quests))}
	for _, quest := range w.questLogValue(p).Quests {
		out.Quests = append(out.Quests, mnet.QuestLogEntry{ID: quest.ID, Title: quest.Title, Objective: quest.Objective, Status: quest.Status})
	}
	return out
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
