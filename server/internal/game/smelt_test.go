package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestStationRecipeMapsOreToBar(t *testing.T) {
	got, ok := stationRecipe(KindSmelter, KindCopperOre)
	if !ok || got != KindCopperBar {
		t.Fatalf("stationRecipe(smelter, copper_ore)=%q ok=%v, want %s", got, ok, KindCopperBar)
	}
	if _, ok := stationRecipe(KindSmelter, KindLogs); ok {
		t.Fatal("stationRecipe accepted logs at a smelter")
	}
	if _, ok := stationRecipe(KindTree, KindCopperOre); ok {
		t.Fatal("stationRecipe accepted ore at a tree")
	}
}

func TestUseOnSmelterConvertsOreToBar(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinBare()
	station := pw.seedSmelter()
	alice.pos = Point{X: SeedSmelterX, Z: SeedSmelterZ}
	ore, err := pw.w.items.SpawnInventoryItem(alice.id, KindCopperOre)
	if err != nil {
		t.Fatalf("seed ore: %v", err)
	}

	pw.w.use(alice, mnet.Use{Slot: ore.Index, On: int(station.id)}, 1)

	bag := pw.w.items.Inventory(alice.id)
	if countKind(bag, KindCopperOre) != 0 {
		t.Fatalf("ore remained after smelt: %+v", bag)
	}
	if countKind(bag, KindCopperBar) != 1 {
		t.Fatalf("bag %+v, want one copper_bar", bag)
	}
	done := pw.events(EvUse)
	if len(done) != 1 {
		t.Fatalf("logged %d %s, want 1", len(done), EvUse)
	}
	if done[0]["from"] != KindCopperOre || done[0]["to"] != KindCopperBar {
		t.Fatalf("%s fields %+v, want from=%s to=%s", EvUse, done[0], KindCopperOre, KindCopperBar)
	}
	if done[0]["station"] != float64(station.id) {
		t.Fatalf("%s station=%v, want %d", EvUse, done[0]["station"], station.id)
	}
}

func TestUseOnSmelterRefusesWrongItem(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinBare()
	station := pw.seedSmelter()
	alice.pos = Point{X: SeedSmelterX, Z: SeedSmelterZ}
	slot, err := pw.w.items.SpawnInventoryItem(alice.id, KindLogs)
	if err != nil {
		t.Fatalf("seed logs: %v", err)
	}

	pw.w.use(alice, mnet.Use{Slot: slot.Index, On: int(station.id)}, 1)

	if countKind(pw.w.items.Inventory(alice.id), KindLogs) != 1 {
		t.Fatal("wrong-item smelt mutated the bag")
	}
	rejected := pw.events(EvUseRejected)
	if len(rejected) != 1 || rejected[0]["reason"] != string(mnet.ReasonNoRecipe) {
		t.Fatalf("use_rejected=%v, want no_recipe", rejected)
	}
}

func TestUseOnSmelterRefusesOutOfRange(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinBare()
	station := pw.seedSmelter()
	alice.pos = Point{X: SeedSmelterX + StationRange + 1, Z: SeedSmelterZ}
	ore, err := pw.w.items.SpawnInventoryItem(alice.id, KindCopperOre)
	if err != nil {
		t.Fatalf("seed ore: %v", err)
	}

	pw.w.use(alice, mnet.Use{Slot: ore.Index, On: int(station.id)}, 1)

	if countKind(pw.w.items.Inventory(alice.id), KindCopperOre) != 1 {
		t.Fatal("out-of-range smelt consumed the ore")
	}
	rejected := pw.events(EvUseRejected)
	if len(rejected) != 1 || rejected[0]["reason"] != string(mnet.ReasonOutOfRange) {
		t.Fatalf("use_rejected=%v, want out_of_range", rejected)
	}
}

func TestUseOnSmelterRefusesEmptySlot(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinBare()
	station := pw.seedSmelter()
	alice.pos = Point{X: SeedSmelterX, Z: SeedSmelterZ}

	pw.w.use(alice, mnet.Use{Slot: 0, On: int(station.id)}, 1)

	rejected := pw.events(EvUseRejected)
	if len(rejected) != 1 || rejected[0]["reason"] != string(mnet.ReasonEmptySlot) {
		t.Fatalf("use_rejected=%v, want empty_slot", rejected)
	}
}

func TestGatherOnSmelterIsRefused(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithClass("miner")
	station := pw.seedSmelter()
	alice.pos = Point{X: SeedSmelterX, Z: SeedSmelterZ}

	pw.gather(alice, station.id)

	if alice.gatherNode != 0 {
		t.Fatalf("gatherNode=%d after smelter gather, want 0", alice.gatherNode)
	}
	rejected := pw.events(EvGatherRejected)
	if len(rejected) != 1 || rejected[0]["reason"] != string(mnet.ReasonNeedsClass) {
		t.Fatalf("gather_rejected=%v, want needs_class", rejected)
	}
}

func (pw *gatherProbe) seedSmelter() *resourceNode {
	pw.t.Helper()
	if err := pw.w.SeedResourceNode(KindSmelter, SeedSmelterX, SeedSmelterZ); err != nil {
		pw.t.Fatalf("seed smelter: %v", err)
	}
	return pw.w.nodes[pw.w.nextNodeID]
}
