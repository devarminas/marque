package net_test

import (
	"testing"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func questGiverID(w mnet.Welcome) mnet.PlayerID {
	for _, n := range w.Npcs {
		if n.Kind == game.KindQuestGiver {
			return n.ID
		}
	}
	return 0
}

func TestAcceptRestatesQuestLog(t *testing.T) {
	h := newHarness(t)
	alice := h.dial("alice")
	welcome := alice.welcome()
	npc := questGiverID(welcome)
	if npc == 0 {
		t.Fatal("welcome lacks quest_giver")
	}

	alice.talk(npc)
	dialog := alice.awaitDialog()
	if dialog.NPC != npc {
		t.Fatalf("dialog npc=%d, want %d", dialog.NPC, npc)
	}

	alice.dialogOption(npc, mnet.OptionAcceptQuest)
	closed := false
	var log mnet.QuestLog
	deadlineFrames := 0
	for deadlineFrames < 20 {
		f := alice.next()
		deadlineFrames++
		switch {
		case f.Dialog != nil && len(f.Dialog.Lines) == 0:
			closed = true
		case f.QuestLog != nil:
			log = *f.QuestLog
		case f.Path != nil:
			continue
		default:
			t.Fatalf("unexpected %s during accept: %s", f.kind(), f.raw)
		}
		if closed && log.Quests != nil {
			break
		}
	}
	if !closed {
		t.Fatal("dialog did not close on accept")
	}
	if len(log.Quests) != 1 {
		t.Fatalf("quest_log=%+v", log)
	}
	e := log.Quests[0]
	if e.ID != "bring_a_stick" || e.Title != "Bring Sticks" || e.Objective != "Deliver 1 sticks" || e.Status != "active" {
		t.Fatalf("entry=%+v", e)
	}
}

func TestReconnectRestatesQuestLog(t *testing.T) {
	h := newHarness(t)
	alice := h.dial("alice")
	welcome := alice.welcome()
	npc := questGiverID(welcome)
	if npc == 0 {
		t.Fatal("welcome lacks quest_giver")
	}

	alice.talk(npc)
	_ = alice.awaitDialog()
	alice.dialogOption(npc, mnet.OptionAcceptQuest)
	_ = alice.awaitQuestLog()

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)

	resumed := h.dialResume("alice-again", welcome.Session)
	step := readJoinStep(resumed)
	if len(step.questLog.Quests) != 1 {
		t.Fatalf("resumed quest_log=%+v", step.questLog)
	}
	e := step.questLog.Quests[0]
	if e.ID != "bring_a_stick" || e.Status != "active" || e.Title != "Bring Sticks" {
		t.Fatalf("entry=%+v", e)
	}
}
