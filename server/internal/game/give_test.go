package game

import (
	"slices"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestGiveStickCompletesQuestAndGrantsMinerBag(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusActive
	stick, err := pw.w.items.SpawnInventoryItem(alice.id, KindStick)
	if err != nil {
		t.Fatal(err)
	}
	q := mustQuest(t, pw.w)

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: stick.Index}, 1)

	if alice.quests["bring_a_stick"] != questStatusComplete {
		t.Fatalf("status=%q", alice.quests["bring_a_stick"])
	}
	if countKind(pw.w.items.Inventory(alice.id), KindStick) != 0 {
		t.Fatal("stick still in bag")
	}
	bag := pw.w.items.Inventory(alice.id)
	kinds := make([]string, len(bag))
	for i, slot := range bag {
		kinds[i] = slot.Kind
	}
	if !slices.Equal(kinds, q.RewardKinds) {
		t.Fatalf("bag=%v want %v", kinds, q.RewardKinds)
	}
	if worn := pw.w.items.Worn(alice.id); len(worn) != 0 {
		t.Fatalf("worn %+v, rewards must stay in the bag", worn)
	}
	if got := pw.events(EvQuestCompleted); len(got) != 1 {
		t.Fatalf("quest_completed=%d", len(got))
	}
	log := pw.w.questLogMessage(alice)
	if len(log.Quests) != 1 || log.Quests[0].Status != string(questStatusComplete) {
		t.Fatalf("quest_log=%+v", log)
	}
}

func TestGiveRefusesWrongItem(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusActive
	slot, err := pw.w.items.SpawnInventoryItem(alice.id, KindAcorn)
	if err != nil {
		t.Fatal(err)
	}

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: slot.Index}, 1)

	if alice.quests["bring_a_stick"] != questStatusActive {
		t.Fatalf("status mutated to %q", alice.quests["bring_a_stick"])
	}
	if countKind(pw.w.items.Inventory(alice.id), KindAcorn) != 1 {
		t.Fatal("acorn mutated")
	}
	if got := pw.events(EvGiveRejected); len(got) != 1 {
		t.Fatalf("give_rejected=%d", len(got))
	}
	if got := pw.events(EvGiveRejected)[0]["reason"]; got != string(mnet.ReasonWrongItem) {
		t.Fatalf("reason=%v", got)
	}
}

func TestGiveRefusesEmptySlot(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusActive

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: 0}, 1)

	if got := pw.events(EvGiveRejected)[0]["reason"]; got != string(mnet.ReasonEmptySlot) {
		t.Fatalf("reason=%v", got)
	}
}

func TestGiveRefusesInactiveQuest(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	slot, err := pw.w.items.SpawnInventoryItem(alice.id, KindStick)
	if err != nil {
		t.Fatal(err)
	}

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: slot.Index}, 1)

	if countKind(pw.w.items.Inventory(alice.id), KindStick) != 1 {
		t.Fatal("stick consumed without active quest")
	}
	if got := pw.events(EvGiveRejected)[0]["reason"]; got != string(mnet.ReasonQuestInactive) {
		t.Fatalf("reason=%v", got)
	}
}

func TestGiveRefusesCompleteQuest(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusComplete
	slot, err := pw.w.items.SpawnInventoryItem(alice.id, KindStick)
	if err != nil {
		t.Fatal(err)
	}

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: slot.Index}, 1)

	if countKind(pw.w.items.Inventory(alice.id), KindStick) != 1 {
		t.Fatal("stick consumed on complete quest")
	}
	if got := pw.events(EvGiveRejected)[0]["reason"]; got != string(mnet.ReasonQuestComplete) {
		t.Fatalf("reason=%v", got)
	}
}

func TestGiveRefusesFullBag(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.pos = giver.pos
	alice.quests["bring_a_stick"] = questStatusActive
	if _, err := pw.w.items.SpawnInventoryItem(alice.id, KindStick); err != nil {
		t.Fatal(err)
	}
	for i := 1; i < InventorySize; i++ {
		if _, err := pw.w.items.SpawnInventoryItem(alice.id, KindAcorn); err != nil {
			t.Fatalf("fill %d: %v", i, err)
		}
	}

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: 0}, 1)

	if alice.quests["bring_a_stick"] != questStatusActive {
		t.Fatalf("status=%q", alice.quests["bring_a_stick"])
	}
	if countKind(pw.w.items.Inventory(alice.id), KindStick) != 1 {
		t.Fatal("stick lost on full bag")
	}
	if got := pw.events(EvGiveRejected)[0]["reason"]; got != string(mnet.ReasonInventoryFull) {
		t.Fatalf("reason=%v", got)
	}
}

func TestGiveRefusesOutOfRange(t *testing.T) {
	pw, giver := newDialogProbe(t)
	alice := pw.join()
	alice.quests["bring_a_stick"] = questStatusActive
	slot, err := pw.w.items.SpawnInventoryItem(alice.id, KindStick)
	if err != nil {
		t.Fatal(err)
	}

	pw.w.give(alice, mnet.Give{NPC: giver.id, Slot: slot.Index}, 1)

	if countKind(pw.w.items.Inventory(alice.id), KindStick) != 1 {
		t.Fatal("stick consumed out of range")
	}
	if got := pw.events(EvGiveRejected)[0]["reason"]; got != string(mnet.ReasonOutOfRange) {
		t.Fatalf("reason=%v", got)
	}
}

func TestGiveRefusesNonQuestNPC(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetQuests(mustLoadQuests(t))
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	dummy := pw.w.npcByKind(KindDummy)
	if dummy == nil {
		t.Fatal("no dummy")
	}
	alice := pw.join()
	alice.pos = dummy.pos
	alice.quests["bring_a_stick"] = questStatusActive
	slot, err := pw.w.items.SpawnInventoryItem(alice.id, KindStick)
	if err != nil {
		t.Fatal(err)
	}

	pw.w.give(alice, mnet.Give{NPC: dummy.id, Slot: slot.Index}, 1)

	if got := pw.events(EvGiveRejected)[0]["reason"]; got != string(mnet.ReasonWrongTarget) {
		t.Fatalf("reason=%v", got)
	}
}
