package game

import (
	"path/filepath"
	"runtime"
	"testing"

	"github.com/devarminas/marque/server/internal/classdef"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/questdef"
)

func mustLoadQuests(t *testing.T) *questdef.Catalog {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	sets, err := classdef.LoadSets(filepath.Join(root, filepath.FromSlash(classdef.SetsRelPath)))
	if err != nil {
		t.Fatalf("LoadSets: %v", err)
	}
	cat, err := questdef.Load(filepath.Join(root, filepath.FromSlash(questdef.RelPath)), sets)
	if err != nil {
		t.Fatalf("Load quests: %v", err)
	}
	return cat
}

func newDialogProbe(t *testing.T) (*probeWorld, *npc) {
	t.Helper()
	pw := newProbeWorld(t)
	pw.w.SetQuests(mustLoadQuests(t))
	if err := pw.w.SeedQuestGiver(); err != nil {
		t.Fatal(err)
	}
	giver := pw.w.npcByKind(KindQuestGiver)
	if giver == nil {
		t.Fatal("quest giver not seeded")
	}
	return pw, giver
}

func (w *World) npcByKind(kind string) *npc {
	for _, id := range w.npcOrder {
		n := w.npcs[id]
		if n != nil && n.kind == kind {
			return n
		}
	}
	return nil
}

func TestSeedQuestGiverDistinctFromDummies(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	if err := pw.w.SeedQuestGiver(); err != nil {
		t.Fatal(err)
	}
	giver := pw.w.npcByKind(KindQuestGiver)
	if giver == nil {
		t.Fatal("missing quest giver")
	}
	if giver.kind != KindQuestGiver || giver.faction != FactionNeutral {
		t.Fatalf("kind=%q faction=%q", giver.kind, giver.faction)
	}
	if giver.pos.X != QuestGiverX || giver.pos.Z != QuestGiverZ {
		t.Fatalf("pos=%v", giver.pos)
	}
	for _, id := range pw.w.npcOrder {
		n := pw.w.npcs[id]
		if n.kind == KindDummy && n.faction == FactionNeutral {
			t.Fatal("dummy reused neutral faction")
		}
	}
}

func TestQuestGiverNotAttackableAsHostile(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	pw.w.attack(alice, mnet.Attack{Player: giver.id}, 1)
	if alice.attackTarget != 0 {
		t.Fatal("attack pending on quest giver")
	}
	if got := pw.events(EvAttackRejected); len(got) != 1 {
		t.Fatalf("attack_rejected=%d", len(got))
	}
	if got := pw.events(EvAttackRejected)[0]["reason"]; got != string(mnet.ReasonWrongTarget) {
		t.Fatalf("reason=%v", got)
	}
}

func TestTalkOpensDialogWithAcceptAndStop(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos

	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	pw.w.step()
	if alice.dialogNPC != giver.id {
		t.Fatalf("dialogNPC=%d, want %d", alice.dialogNPC, giver.id)
	}
	if alice.pendingTalk != 0 {
		t.Fatalf("pendingTalk=%d after resolve", alice.pendingTalk)
	}
	msg := pw.w.dialogMessage(alice, giver, mustQuest(t, pw.w))
	if len(msg.Lines) == 0 {
		t.Fatal("empty lines")
	}
	ids := optionIDs(msg)
	if !containsID(ids, mnet.OptionAcceptQuest) || !containsID(ids, mnet.OptionStopTalking) {
		t.Fatalf("options=%v", ids)
	}
	if got := pw.events(EvTalkResolved); len(got) != 1 {
		t.Fatalf("talk_resolved=%d", len(got))
	}
}

func TestTalkFromOutOfRangeWalksThenOpens(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()

	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	if alice.pendingTalk != giver.id {
		t.Fatalf("pendingTalk=%d", alice.pendingTalk)
	}
	if alice.dialogNPC != 0 {
		t.Fatal("dialog opened before arrival")
	}
	if !alice.walking() {
		t.Fatal("talk assigned no path")
	}
	for i := 0; i < 80 && alice.dialogNPC == 0; i++ {
		pw.w.step()
	}
	if alice.dialogNPC != giver.id {
		t.Fatalf("dialogNPC=%d after walk", alice.dialogNPC)
	}
}

func TestStopTalkingClearsWithoutAccept(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	pw.w.step()

	pw.w.dialogOption(alice, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionStopTalking}, 2)
	if alice.dialogNPC != 0 {
		t.Fatalf("dialogNPC=%d after stop", alice.dialogNPC)
	}
	if alice.quests["bring_a_stick"] != "" {
		t.Fatalf("quest status=%q after stop", alice.quests["bring_a_stick"])
	}
}

func TestAcceptRecordsQuestAndCloses(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	pw.w.step()

	pw.w.dialogOption(alice, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionAcceptQuest}, 2)
	if alice.quests["bring_a_stick"] != questStatusActive {
		t.Fatalf("status=%q", alice.quests["bring_a_stick"])
	}
	if alice.dialogNPC != 0 {
		t.Fatalf("dialogNPC=%d after accept", alice.dialogNPC)
	}
	if got := pw.events(EvQuestAccepted); len(got) != 1 {
		t.Fatalf("quest_accepted=%d", len(got))
	}
}

func TestReAcceptWhileActiveRefuses(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusActive

	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	pw.w.step()
	msg := pw.w.dialogMessage(alice, giver, mustQuest(t, pw.w))
	if containsID(optionIDs(msg), mnet.OptionAcceptQuest) {
		t.Fatalf("accept still offered: %v", optionIDs(msg))
	}

	alice.dialogNPC = giver.id
	pw.w.dialogOption(alice, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionAcceptQuest}, 2)
	if alice.quests["bring_a_stick"] != questStatusActive {
		t.Fatalf("status mutated to %q", alice.quests["bring_a_stick"])
	}
	if got := pw.events(EvDialogOptionRejected); len(got) != 1 {
		t.Fatalf("dialog_option_rejected=%d", len(got))
	}
	if got := pw.events(EvDialogOptionRejected)[0]["reason"]; got != string(mnet.ReasonQuestActive) {
		t.Fatalf("reason=%v", got)
	}
	if got := pw.events(EvQuestAccepted); len(got) != 0 {
		t.Fatal("duplicate quest_accepted")
	}
}

func TestAcceptWhileCompleteRefuses(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusComplete
	alice.dialogNPC = giver.id

	pw.w.dialogOption(alice, mnet.DialogOptionPick{NPC: giver.id, Option: mnet.OptionAcceptQuest}, 1)
	if alice.quests["bring_a_stick"] != questStatusComplete {
		t.Fatalf("status=%q", alice.quests["bring_a_stick"])
	}
	if got := pw.events(EvDialogOptionRejected)[0]["reason"]; got != string(mnet.ReasonQuestComplete) {
		t.Fatalf("reason=%v", got)
	}
}

func TestTalkRefusesDummy(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetQuests(mustLoadQuests(t))
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	alice := pw.join()
	dummy := pw.w.npcByFaction(FactionFriendly)
	alice.pos = dummy.pos
	pw.w.talk(alice, mnet.Talk{NPC: dummy.id}, 1)
	if alice.pendingTalk != 0 || alice.dialogNPC != 0 {
		t.Fatal("talk pending on dummy")
	}
	if got := pw.events(EvTalkRejected)[0]["reason"]; got != string(mnet.ReasonWrongTarget) {
		t.Fatalf("reason=%v", got)
	}
}

func TestDeathClearsPendingTalkAndDialog(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	bob := pw.join()
	pw.w.talk(alice, mnet.Talk{NPC: giver.id}, 1)
	if alice.pendingTalk != giver.id {
		t.Fatalf("pendingTalk=%d", alice.pendingTalk)
	}
	alice.pos = giver.pos
	pw.w.step()
	if alice.dialogNPC != giver.id {
		t.Fatalf("dialogNPC=%d", alice.dialogNPC)
	}
	bob.pos = alice.pos
	alice.hp = AttackDamage
	pw.w.beginAttack(bob, alice.id, alice.pos, 2)
	pw.stepN(AttackPeriodTicks)
	if !alice.dead() {
		t.Fatalf("alice hp=%d, want dead", alice.hp)
	}
	if alice.pendingTalk != 0 || alice.dialogNPC != 0 {
		t.Fatalf("pendingTalk=%d dialogNPC=%d after death", alice.pendingTalk, alice.dialogNPC)
	}
}

func mustQuest(t *testing.T, w *World) questdef.Quest {
	t.Helper()
	q, ok := w.questForTalkNPC(KindQuestGiver)
	if !ok {
		t.Fatal("no quest for quest_giver")
	}
	return q
}

func optionIDs(d mnet.Dialog) []string {
	out := make([]string, 0, len(d.Options))
	for _, o := range d.Options {
		out = append(out, o.ID)
	}
	return out
}

func containsID(ids []string, want string) bool {
	for _, id := range ids {
		if id == want {
			return true
		}
	}
	return false
}
