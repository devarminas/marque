package game


import (
	"errors"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestItemIdsComeFromTheirOwnSequence(t *testing.T) {
	s := NewMemoryStore(NoWearables)

	s.AddPlayer(1)
	s.AddPlayer(2)

	first := s.SpawnGroundItem(KindAcorn, 1, 1)
	second := s.SpawnGroundItem(KindAcorn, 2, 2)
	if first.ID != 1 || second.ID != 2 {
		t.Fatalf("item ids are %d and %d, want 1 and 2 from an item-only counter", first.ID, second.ID)
	}
}

func TestItemIdsAreNeverReused(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)

	taken := s.SpawnGroundItem(KindAcorn, 1, 1)
	if _, err := s.TakeGroundItem(taken.ID, 1); err != nil {
		t.Fatalf("taking item %d: %v", taken.ID, err)
	}

	next := s.SpawnGroundItem(KindAcorn, 2, 2)
	if next.ID == taken.ID {
		t.Fatalf("a new item reused id %d, which a taken item already had", next.ID)
	}
}

func TestTakeIsOneMove(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(7)
	item := s.SpawnGroundItem(KindAcorn, 3, -2)

	slot, err := s.TakeGroundItem(item.ID, 7)
	if err != nil {
		t.Fatalf("taking item %d: %v", item.ID, err)
	}
	if slot.Index != 0 || slot.Kind != KindAcorn {
		t.Fatalf("landed in slot %+v, want index 0 holding %q", slot, KindAcorn)
	}
	if _, onGround := s.GroundItem(item.ID); onGround {
		t.Fatal("the item is in an inventory and still on the ground")
	}
	if got := s.Inventory(7); len(got) != 1 || got[0] != slot {
		t.Fatalf("inventory holds %+v, want exactly the slot the move reported: %+v", got, slot)
	}
}

func TestSecondTakeOfTheSameItemFails(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	s.AddPlayer(2)
	item := s.SpawnGroundItem(KindAcorn, 0, 0)

	if _, err := s.TakeGroundItem(item.ID, 1); err != nil {
		t.Fatalf("first take: %v", err)
	}

	_, err := s.TakeGroundItem(item.ID, 2)
	if !errors.Is(err, ErrNoSuchItem) {
		t.Fatalf("second take returned %v, want ErrNoSuchItem", err)
	}
	if got := s.Inventory(2); len(got) != 0 {
		t.Fatalf("the loser's inventory holds %+v, want nothing", got)
	}
}

func TestTakingWhatIsNotThereFails(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)

	if _, err := s.TakeGroundItem(mnet.ItemID(99), 1); !errors.Is(err, ErrNoSuchItem) {
		t.Fatalf("taking an id that never existed returned %v, want ErrNoSuchItem", err)
	}
}

func TestSlotsFillLowestFirst(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)

	for want := range 3 {
		item := s.SpawnGroundItem(KindAcorn, 0, 0)
		slot, err := s.TakeGroundItem(item.ID, 1)
		if err != nil {
			t.Fatalf("take %d: %v", want, err)
		}
		if slot.Index != want {
			t.Fatalf("take %d landed in slot %d, want %d", want, slot.Index, want)
		}
	}
}

func TestAFullInventoryRefusesAndKeepsTheItemOnTheGround(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)

	for i := range InventorySize {
		item := s.SpawnGroundItem(KindAcorn, 0, 0)
		if _, err := s.TakeGroundItem(item.ID, 1); err != nil {
			t.Fatalf("filling slot %d: %v", i, err)
		}
	}

	overflow := s.SpawnGroundItem(KindAcorn, 4, 4)
	if _, err := s.TakeGroundItem(overflow.ID, 1); !errors.Is(err, ErrInventoryFull) {
		t.Fatalf("take into a full inventory returned %v, want ErrInventoryFull", err)
	}
	if _, onGround := s.GroundItem(overflow.ID); !onGround {
		t.Fatal("a refused take removed the item from the ground anyway")
	}
	if got := len(s.Inventory(1)); got != InventorySize {
		t.Fatalf("inventory holds %d items, want %d", got, InventorySize)
	}
}

func TestTakingForAnUnknownPlayerFails(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	item := s.SpawnGroundItem(KindAcorn, 0, 0)

	if _, err := s.TakeGroundItem(item.ID, 42); !errors.Is(err, ErrNoSuchPlayer) {
		t.Fatalf("take for a player with no inventory returned %v, want ErrNoSuchPlayer", err)
	}
	if _, onGround := s.GroundItem(item.ID); !onGround {
		t.Fatal("a take for an unknown player removed the item from the ground")
	}
}

func TestGroundItemsAreListedOldestFirst(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)

	for i := range 6 {
		s.SpawnGroundItem(KindAcorn, float64(i), 0)
	}
	if _, err := s.TakeGroundItem(3, 1); err != nil {
		t.Fatalf("taking item 3: %v", err)
	}

	want := []mnet.ItemID{1, 2, 4, 5, 6}
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

func TestRemovingAPlayerTakesTheirItemsWithThem(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	item := s.SpawnGroundItem(KindAcorn, 0, 0)
	if _, err := s.TakeGroundItem(item.ID, 1); err != nil {
		t.Fatalf("taking item %d: %v", item.ID, err)
	}

	s.RemovePlayer(1)

	if got := s.Inventory(1); got != nil {
		t.Fatalf("a departed player still has an inventory: %+v", got)
	}
	if _, onGround := s.GroundItem(item.ID); onGround {
		t.Fatal("what they were carrying reappeared on the ground; M1 has no drop-on-logout")
	}
	s.RemovePlayer(1)
}
