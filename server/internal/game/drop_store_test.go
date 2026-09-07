package game


import (
	"errors"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestDropIsOneMove(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(7)
	taken := s.SpawnGroundItem(KindAcorn, 3, -2)
	if _, err := s.TakeGroundItem(taken.ID, 7); err != nil {
		t.Fatalf("taking item %d: %v", taken.ID, err)
	}

	dropped, err := s.DropInventorySlot(7, 0, 5, 6)
	if err != nil {
		t.Fatalf("dropping slot 0: %v", err)
	}

	if dropped.Kind != KindAcorn || dropped.X != 5 || dropped.Z != 6 {
		t.Fatalf("dropped %+v, want an acorn at (5, 6)", dropped)
	}
	if got := s.Inventory(7); len(got) != 0 {
		t.Fatalf("the slot still holds %+v after the item left it", got)
	}
	onGround, ok := s.GroundItem(dropped.ID)
	if !ok {
		t.Fatal("the item left the inventory and never reached the ground")
	}
	if onGround != dropped {
		t.Fatalf("the ground holds %+v, want exactly what the move reported: %+v", onGround, dropped)
	}
}

func TestADroppedItemGetsANewId(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	taken := s.SpawnGroundItem(KindAcorn, 0, 0)
	if _, err := s.TakeGroundItem(taken.ID, 1); err != nil {
		t.Fatalf("taking item %d: %v", taken.ID, err)
	}

	dropped, err := s.DropInventorySlot(1, 0, 0, 0)
	if err != nil {
		t.Fatalf("dropping slot 0: %v", err)
	}

	if dropped.ID == taken.ID {
		t.Fatalf("the dropped item came back as id %d, which a taken item already had", dropped.ID)
	}
	if dropped.ID != taken.ID+1 {
		t.Fatalf("the dropped item is id %d, want %d from the item counter", dropped.ID, taken.ID+1)
	}
}

func TestTakeAndDropRoundTripReturnsTheStoreToItsShape(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	first := s.SpawnGroundItem(KindAcorn, 2, 2)

	if _, err := s.TakeGroundItem(first.ID, 1); err != nil {
		t.Fatalf("taking: %v", err)
	}
	dropped, err := s.DropInventorySlot(1, 0, 2, 2)
	if err != nil {
		t.Fatalf("dropping: %v", err)
	}
	slot, err := s.TakeGroundItem(dropped.ID, 1)
	if err != nil {
		t.Fatalf("taking the item back: %v", err)
	}

	if slot.Index != 0 || slot.Kind != KindAcorn {
		t.Fatalf("the item came back to %+v, want slot 0 holding %q", slot, KindAcorn)
	}
	if got := s.Inventory(1); len(got) != 1 || got[0] != slot {
		t.Fatalf("inventory holds %+v, want the one slot it started with", got)
	}
	if items := s.GroundItems(); len(items) != 0 {
		t.Fatalf("the ground holds %+v after the item was taken back", items)
	}
}

func TestDroppingAnEmptySlotChangesNothing(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	item := s.SpawnGroundItem(KindAcorn, 0, 0)
	if _, err := s.TakeGroundItem(item.ID, 1); err != nil {
		t.Fatalf("taking item %d: %v", item.ID, err)
	}

	for _, slot := range []int{1, InventorySize - 1} {
		if _, err := s.DropInventorySlot(1, slot, 0, 0); !errors.Is(err, ErrEmptySlot) {
			t.Fatalf("dropping empty slot %d returned %v, want ErrEmptySlot", slot, err)
		}
	}

	if got := s.Inventory(1); len(got) != 1 || got[0].Index != 0 {
		t.Fatalf("a refused drop left the inventory as %+v, want the one acorn in slot 0", got)
	}
	if items := s.GroundItems(); len(items) != 0 {
		t.Fatalf("a refused drop put %+v on the ground", items)
	}
}

func TestDroppingAnIndexOutsideTheInventoryChangesNothing(t *testing.T) {
	for _, slot := range []int{-1, InventorySize, InventorySize + 1000} {
		s := NewMemoryStore(NoWearables)
		s.AddPlayer(1)
		item := s.SpawnGroundItem(KindAcorn, 0, 0)
		if _, err := s.TakeGroundItem(item.ID, 1); err != nil {
			t.Fatalf("taking item %d: %v", item.ID, err)
		}

		if _, err := s.DropInventorySlot(1, slot, 0, 0); !errors.Is(err, ErrNoSuchSlot) {
			t.Fatalf("dropping slot %d returned %v, want ErrNoSuchSlot", slot, err)
		}
		if got := s.Inventory(1); len(got) != 1 {
			t.Fatalf("dropping slot %d left the inventory as %+v, want the acorn untouched", slot, got)
		}
		if items := s.GroundItems(); len(items) != 0 {
			t.Fatalf("dropping slot %d put %+v on the ground", slot, items)
		}
	}
}

func TestDroppingForAnUnknownPlayerFails(t *testing.T) {
	s := NewMemoryStore(NoWearables)

	if _, err := s.DropInventorySlot(mnet.PlayerID(42), 0, 0, 0); !errors.Is(err, ErrNoSuchPlayer) {
		t.Fatalf("dropping for a player with no inventory returned %v, want ErrNoSuchPlayer", err)
	}
	if items := s.GroundItems(); len(items) != 0 {
		t.Fatalf("a drop for an unknown player put %+v on the ground", items)
	}
}

func TestADroppedItemJoinsTheBackOfTheGroundOrder(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)

	first := s.SpawnGroundItem(KindAcorn, 1, 0)
	second := s.SpawnGroundItem(KindAcorn, 2, 0)
	if _, err := s.TakeGroundItem(first.ID, 1); err != nil {
		t.Fatalf("taking item %d: %v", first.ID, err)
	}
	dropped, err := s.DropInventorySlot(1, 0, 3, 0)
	if err != nil {
		t.Fatalf("dropping slot 0: %v", err)
	}

	want := []mnet.ItemID{second.ID, dropped.ID}
	got := s.GroundItems()
	if len(got) != len(want) {
		t.Fatalf("listed %d items, want %d: %+v", len(got), len(want), got)
	}
	for i, id := range want {
		if got[i].ID != id {
			t.Fatalf("item %d in the list is %d, want %d: %+v", i, got[i].ID, id, got)
		}
	}
}
