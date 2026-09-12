package game

import (
	"slices"
	"testing"

	"github.com/devarminas/marque/server/internal/classdef"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func seedImpQuestGiver(t *testing.T, w *World) *npc {
	t.Helper()
	if err := w.SeedImpQuestGiver(); err != nil {
		t.Fatal(err)
	}
	giver := w.npcByKind(KindImpQuestGiver)
	if giver == nil {
		t.Fatal("imp quest giver not seeded")
	}
	return giver
}

func acceptImpQuest(t *testing.T, pw *probeWorld, giver *npc, p *player) {
	t.Helper()
	p.pos = giver.pos
	pw.w.talk(p, mnet.Talk{NPC: giver.id}, 1)
	pw.w.step()
	pw.w.dialogOption(p, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionAcceptQuest}, 2)
	if p.quests["slay_imps"] != questStatusActive {
		t.Fatalf("status=%q", p.quests["slay_imps"])
	}
}

func killImpWith(t *testing.T, pw *probeWorld, killer *player, imp *npc) {
	t.Helper()
	killer.pos = imp.pos
	pw.w.attack(killer, mnet.Attack{Player: imp.id}, 1)
	for imp.hp > 0 {
		for range pw.playerPeriod(killer) {
			pw.w.step()
		}
	}
}

func TestSeedImpQuestGiverDistinctFromStickGiver(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.SeedQuestGiver(); err != nil {
		t.Fatal(err)
	}
	giver := seedImpQuestGiver(t, pw.w)
	stick := pw.w.npcByKind(KindQuestGiver)
	if stick == nil {
		t.Fatal("missing stick giver")
	}
	if stick.id == giver.id || stick.kind == giver.kind {
		t.Fatalf("stick=%+v imp=%+v", stick, giver)
	}
	if giver.pos.X != ImpQuestGiverX || giver.pos.Z != ImpQuestGiverZ {
		t.Fatalf("imp giver pos=%v", giver.pos)
	}
}

func TestKillImpProgressesActiveQuest(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetQuests(mustLoadQuests(t))
	giver := seedImpQuestGiver(t, pw.w)
	alice := pw.joinWithClass("knight")
	acceptImpQuest(t, pw.probeWorld, giver, alice)
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)

	killImpWith(t, pw.probeWorld, alice, imp)

	if alice.questKillCount("slay_imps") != 1 {
		t.Fatalf("progress=%d", alice.questKillCount("slay_imps"))
	}
	log := pw.w.questLogMessage(alice)
	if len(log.Quests) != 1 || log.Quests[0].Objective != "Slay 5 imps (1/5)" {
		t.Fatalf("quest_log=%+v", log)
	}
	if got := pw.events(EvQuestKillProgress); len(got) != 1 {
		t.Fatalf("quest_kill_progress=%d", len(got))
	}
}

func TestKillImpIgnoresInactiveQuest(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetQuests(mustLoadQuests(t))
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)

	killImpWith(t, pw.probeWorld, alice, imp)

	if alice.questKillCount("slay_imps") != 0 {
		t.Fatalf("progress=%d without active quest", alice.questKillCount("slay_imps"))
	}
	if got := pw.events(EvQuestKillProgress); len(got) != 0 {
		t.Fatalf("unexpected progress events: %+v", got)
	}
}

func TestPartyKillCreditAnywhereInParty(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetQuests(mustLoadQuests(t))
	giver := seedImpQuestGiver(t, pw.w)
	alice := pw.joinWithClass("knight")
	bob := pw.joinWithClass("knight")
	acceptImpQuest(t, pw.probeWorld, giver, alice)
	acceptImpQuest(t, pw.probeWorld, giver, bob)

	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)

	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	bob.pos = Point{X: 0, Z: 0}

	killImpWith(t, pw.probeWorld, alice, imp)

	if alice.questKillCount("slay_imps") != 1 {
		t.Fatalf("alice progress=%d", alice.questKillCount("slay_imps"))
	}
	if bob.questKillCount("slay_imps") != 1 {
		t.Fatalf("bob progress=%d far from kill", bob.questKillCount("slay_imps"))
	}
	if got := pw.events(EvQuestKillProgress); len(got) != 2 {
		t.Fatalf("quest_kill_progress=%d want 2", len(got))
	}
}

func TestTurnInKillQuestCompletesAndGrants(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetQuests(mustLoadQuests(t))
	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatal(err)
	}
	pw.w.SetClasses(classes)
	giver := seedImpQuestGiver(t, pw.w)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["slay_imps"] = questStatusActive
	alice.setQuestKillCount("slay_imps", 5)
	q, ok := pw.w.quests.Get("slay_imps")
	if !ok {
		t.Fatal("missing slay_imps")
	}

	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	pw.w.step()
	msg := pw.w.dialogMessage(alice, giver, q)
	if !containsID(optionIDs(msg), mnet.OptionTurnInQuest) {
		t.Fatalf("options=%v", optionIDs(msg))
	}

	pw.w.dialogOption(alice, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionTurnInQuest}, 2)

	if alice.quests["slay_imps"] != questStatusComplete {
		t.Fatalf("status=%q", alice.quests["slay_imps"])
	}
	bag := pw.w.items.Inventory(alice.id)
	kinds := make([]string, len(bag))
	for i, slot := range bag {
		kinds[i] = slot.Kind
	}
	if !slices.Equal(kinds, q.RewardKinds) {
		t.Fatalf("bag=%v want %v", kinds, q.RewardKinds)
	}
	if got := pw.events(EvQuestCompleted); len(got) != 1 {
		t.Fatalf("quest_completed=%d", len(got))
	}
}

func TestTurnInKillQuestRefusesIncomplete(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetQuests(mustLoadQuests(t))
	giver := seedImpQuestGiver(t, pw.w)
	alice := pw.join()
	alice.pos = giver.pos
	alice.dialogNPC = giver.id
	alice.quests["slay_imps"] = questStatusActive
	alice.setQuestKillCount("slay_imps", 2)

	pw.w.dialogOption(alice, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionTurnInQuest}, 1)

	if alice.quests["slay_imps"] != questStatusActive {
		t.Fatalf("status=%q", alice.quests["slay_imps"])
	}
	if got := pw.events(EvDialogOptionRejected)[0]["reason"]; got != string(mnet.ReasonQuestIncomplete) {
		t.Fatalf("reason=%v", got)
	}
}
