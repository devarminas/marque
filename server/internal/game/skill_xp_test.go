package game

import (
	"testing"

	"github.com/devarminas/marque/server/internal/classdef"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestImpKillGrantsClassSkillXP(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)

	killImpWith(t, pw.probeWorld, alice, imp)

	if got := alice.skillXP["combat"]; got != SkillXPKill {
		t.Fatalf("combat xp=%d, want %d", got, SkillXPKill)
	}
	if got := alice.skillXP["woodcutting"]; got != 0 {
		t.Fatalf("woodcutting xp=%d, want 0", got)
	}
	ev := pw.events(EvSkillXP)
	if len(ev) != 1 {
		t.Fatalf("logged %d %s, want 1", len(ev), EvSkillXP)
	}
	if ev[0]["skill"] != "combat" {
		t.Fatalf("skill_xp skill=%v, want combat", ev[0]["skill"])
	}
	if ev[0]["xp"] != float64(SkillXPKill) {
		t.Fatalf("skill_xp xp=%v, want %d", ev[0]["xp"], SkillXPKill)
	}
	skills := pw.w.skillsMessage(alice)
	var combat mnet.SkillXP
	for _, s := range skills.Skills {
		if s.ID == "combat" {
			combat = s
		}
	}
	if combat.XP != SkillXPKill {
		t.Fatalf("skills restatement combat xp=%d, want %d", combat.XP, SkillXPKill)
	}
}

func TestImpKillWithoutClassGrantsNoXP(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinBare()
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)

	pw.w.killImp(imp, alice.id)

	if len(alice.skillXP) != 0 {
		t.Fatalf("skillXP=%v, want empty without class", alice.skillXP)
	}
	if got := pw.events(EvSkillXP); len(got) != 0 {
		t.Fatalf("logged %d %s, want 0", len(got), EvSkillXP)
	}
}

func TestStickQuestCompleteGrantsClassSkillXP(t *testing.T) {
	pw, giver := newDialogProbe(t)
	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatal(err)
	}
	pw.w.SetClasses(classes)
	cp := &classProbe{probeWorld: pw}
	alice := cp.joinWithClass("miner")
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusActive
	sticks, err := pw.w.items.SpawnInventoryItem(alice.id, KindSticks)
	if err != nil {
		t.Fatal(err)
	}

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: sticks.Index}, 1)

	if alice.quests["bring_a_stick"] != questStatusComplete {
		t.Fatalf("status=%q", alice.quests["bring_a_stick"])
	}
	if got := alice.skillXP["mining"]; got != SkillXPQuest {
		t.Fatalf("mining xp=%d, want %d", got, SkillXPQuest)
	}
	ev := pw.events(EvSkillXP)
	if len(ev) != 1 || ev[0]["skill"] != "mining" {
		t.Fatalf("skill_xp=%v, want mining once", ev)
	}
	if ev[0]["xp"] != float64(SkillXPQuest) {
		t.Fatalf("skill_xp xp=%v, want %d", ev[0]["xp"], SkillXPQuest)
	}
}

func TestStickQuestCompleteWithoutClassGrantsNoXP(t *testing.T) {
	pw, giver := newDialogProbe(t)
	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatal(err)
	}
	pw.w.SetClasses(classes)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusActive
	sticks, err := pw.w.items.SpawnInventoryItem(alice.id, KindSticks)
	if err != nil {
		t.Fatal(err)
	}

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: sticks.Index}, 1)

	if alice.quests["bring_a_stick"] != questStatusComplete {
		t.Fatalf("status=%q", alice.quests["bring_a_stick"])
	}
	if len(alice.skillXP) != 0 {
		t.Fatalf("skillXP=%v, want empty without class", alice.skillXP)
	}
	if got := pw.events(EvSkillXP); len(got) != 0 {
		t.Fatalf("logged %d %s, want 0", len(got), EvSkillXP)
	}
}

func TestKillQuestTurnInGrantsClassSkillXP(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetQuests(mustLoadQuests(t))
	giver := seedImpQuestGiver(t, pw.w)
	alice := pw.joinWithClass("mage")
	alice.pos = giver.pos
	alice.quests["slay_imps"] = questStatusActive
	alice.setQuestKillCount("slay_imps", 5)

	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	pw.w.step()
	pw.w.dialogOption(alice, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionTurnInQuest}, 2)

	if alice.quests["slay_imps"] != questStatusComplete {
		t.Fatalf("status=%q", alice.quests["slay_imps"])
	}
	if got := alice.skillXP["magic"]; got != SkillXPQuest {
		t.Fatalf("magic xp=%d, want %d", got, SkillXPQuest)
	}
	ev := pw.events(EvSkillXP)
	if len(ev) != 1 || ev[0]["skill"] != "magic" {
		t.Fatalf("skill_xp=%v, want magic once", ev)
	}
	if ev[0]["xp"] != float64(SkillXPQuest) {
		t.Fatalf("skill_xp xp=%v, want %d", ev[0]["xp"], SkillXPQuest)
	}
}
