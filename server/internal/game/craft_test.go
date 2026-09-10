package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestSelfUseRecipeMapsBarAndSticksToSword(t *testing.T) {
	got, ok := selfUseRecipeFor(KindCopperBar)
	if !ok || got.Produce != KindSword {
		t.Fatalf("selfUseRecipeFor(copper_bar)=%+v ok=%v, want sword", got, ok)
	}
	got, ok = selfUseRecipeFor(KindSticks)
	if !ok || got.Produce != KindSword {
		t.Fatalf("selfUseRecipeFor(sticks)=%+v ok=%v, want sword", got, ok)
	}
	got, ok = selfUseRecipeFor(KindLogs)
	if !ok || got.Produce != KindSticks {
		t.Fatalf("selfUseRecipeFor(logs)=%+v ok=%v, want sticks", got, ok)
	}
	if _, ok := selfUseRecipeFor(KindAcorn); ok {
		t.Fatal("selfUseRecipeFor accepted acorn")
	}
}

func TestUseCraftsSwordFromBarAndSticks(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinBare()
	bar, err := pw.w.items.SpawnInventoryItem(alice.id, KindCopperBar)
	if err != nil {
		t.Fatalf("seed copper_bar: %v", err)
	}
	if _, err := pw.w.items.SpawnInventoryItem(alice.id, KindSticks); err != nil {
		t.Fatalf("seed sticks: %v", err)
	}

	pw.w.use(alice, mnet.Use{Slot: bar.Index, On: bar.Index}, 1)

	bag := pw.w.items.Inventory(alice.id)
	if countKind(bag, KindCopperBar) != 0 || countKind(bag, KindSticks) != 0 {
		t.Fatalf("ingredients remained: %+v", bag)
	}
	if countKind(bag, KindSword) != 1 {
		t.Fatalf("bag %+v, want one sword", bag)
	}
	done := pw.events(EvUse)
	if len(done) != 1 {
		t.Fatalf("logged %d %s, want 1", len(done), EvUse)
	}
	if done[0]["from"] != KindCopperBar || done[0]["to"] != KindSword {
		t.Fatalf("%s fields %+v, want from=%s to=%s", EvUse, done[0], KindCopperBar, KindSword)
	}
}

func TestUseSwordCraftRefusesMissingSticks(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinBare()
	bar, err := pw.w.items.SpawnInventoryItem(alice.id, KindCopperBar)
	if err != nil {
		t.Fatalf("seed copper_bar: %v", err)
	}

	pw.w.use(alice, mnet.Use{Slot: bar.Index, On: bar.Index}, 1)

	if countKind(pw.w.items.Inventory(alice.id), KindCopperBar) != 1 {
		t.Fatal("missing-sticks craft mutated the bag")
	}
	rejected := pw.events(EvUseRejected)
	if len(rejected) != 1 || rejected[0]["reason"] != string(mnet.ReasonNoRecipe) {
		t.Fatalf("use_rejected=%v, want no_recipe", rejected)
	}
}

func TestCraftedSwordEquipsRightHand(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinBare()
	bar, err := pw.w.items.SpawnInventoryItem(alice.id, KindCopperBar)
	if err != nil {
		t.Fatalf("seed copper_bar: %v", err)
	}
	if _, err := pw.w.items.SpawnInventoryItem(alice.id, KindSticks); err != nil {
		t.Fatalf("seed sticks: %v", err)
	}

	pw.w.use(alice, mnet.Use{Slot: bar.Index, On: bar.Index}, 1)

	bag := pw.w.items.Inventory(alice.id)
	if len(bag) != 1 || bag[0].Kind != KindSword {
		t.Fatalf("bag %+v, want one sword before equip", bag)
	}

	pw.w.equip(alice, mnet.Equip{Slot: bag[0].Index}, 2)

	worn := pw.w.items.Worn(alice.id)
	if len(worn) != 1 || worn[0].Slot != SlotRightHand || worn[0].Kind != KindSword {
		t.Fatalf("worn %+v, want sword in right hand", worn)
	}
	if len(pw.w.items.Inventory(alice.id)) != 0 {
		t.Fatalf("bag not empty after equip: %+v", pw.w.items.Inventory(alice.id))
	}
}
