package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestQuestLogMessageEmpty(t *testing.T) {
	pw, _ := newDialogProbe(t)
	alice := pw.join()
	got := pw.w.questLogMessage(alice)
	if got.Quests == nil {
		t.Fatal("quests is nil")
	}
	if len(got.Quests) != 0 {
		t.Fatalf("quests=%+v", got.Quests)
	}
}

func TestQuestLogMessageActiveFromContent(t *testing.T) {
	pw, _ := newDialogProbe(t)
	alice := pw.join()
	alice.quests["bring_a_stick"] = questStatusActive
	got := pw.w.questLogMessage(alice)
	if len(got.Quests) != 1 {
		t.Fatalf("quests=%+v", got.Quests)
	}
	e := got.Quests[0]
	if e.ID != "bring_a_stick" || e.Title != "Bring Sticks" || e.Objective != "Deliver 1 sticks" || e.Status != string(questStatusActive) {
		t.Fatalf("entry=%+v", e)
	}
}

func TestAcceptRestatesQuestLog(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	pw.w.step()

	pw.w.dialogOption(alice, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionAcceptQuest}, 2)
	if alice.quests["bring_a_stick"] != questStatusActive {
		t.Fatalf("status=%q", alice.quests["bring_a_stick"])
	}
	got := pw.w.questLogMessage(alice)
	if len(got.Quests) != 1 || got.Quests[0].Status != string(questStatusActive) {
		t.Fatalf("quest_log=%+v", got)
	}
}

func TestJoinStepIncludesQuestLog(t *testing.T) {
	pw, _ := newDialogProbe(t)
	alice := pw.join()
	alice.quests["bring_a_stick"] = questStatusActive
	got := pw.w.questLogMessage(alice)
	if len(got.Quests) != 1 || got.Quests[0].ID != "bring_a_stick" {
		t.Fatalf("quest_log=%+v", got)
	}
}
