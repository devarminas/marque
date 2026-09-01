package game

// In-package: memStore is unexported by design, and the properties worth
// pinning here are the ones a Postgres implementation will have to reproduce.
// Every one of these tests is a sentence about the Store interface, not about
// the map behind it.

import (
	"errors"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

// TestItemIdsComeFromTheirOwnSequence is the id-space rule: from 1, ascending,
// and unrelated to any player id. The distinct Go types stop the two being
// confused at compile time; this pins that they are also not accidentally
// numbered from a shared counter.
func TestItemIdsComeFromTheirOwnSequence(t *testing.T) {
	s := NewMemoryStore()

	// Players first, so a shared counter would show up as items starting at 3.
	s.AddPlayer(1)
	s.AddPlayer(2)

	first := s.SpawnGroundItem(KindAcorn, 1, 1)
	second := s.SpawnGroundItem(KindAcorn, 2, 2)
	if first.ID != 1 || second.ID != 2 {
		t.Fatalf("item ids are %d and %d, want 1 and 2 from an item-only counter", first.ID, second.ID)
	}
}

// TestItemIdsAreNeverReused matters because a client caches item ids. If a
// taken id came back on a later item, an M1c client would be told to spawn a
// body it thinks it already has.
func TestItemIdsAreNeverReused(t *testing.T) {
	s := NewMemoryStore()
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

// TestTakeIsOneMove is the interface's reason to exist. One call moves the item
// from the ground into a slot; afterwards it is in exactly one of the two
// places, never both and never neither.
func TestTakeIsOneMove(t *testing.T) {
	s := NewMemoryStore()
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

// TestSecondTakeOfTheSameItemFails is the contested pickup, at the layer that
// decides it. The second caller learns the item is gone and nothing about the
// world moves.
func TestSecondTakeOfTheSameItemFails(t *testing.T) {
	s := NewMemoryStore()
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

// TestTakingWhatIsNotThereFails covers a fabricated id, which the world answers
// identically to a stale one.
func TestTakingWhatIsNotThereFails(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)

	if _, err := s.TakeGroundItem(mnet.ItemID(99), 1); !errors.Is(err, ErrNoSuchItem) {
		t.Fatalf("taking an id that never existed returned %v, want ErrNoSuchItem", err)
	}
}

// TestSlotsFillLowestFirst is RuneScape's rule, and it is the store's to keep
// because the caller cannot name a slot without reading the inventory first.
func TestSlotsFillLowestFirst(t *testing.T) {
	s := NewMemoryStore()
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

// TestAFullInventoryRefusesAndKeepsTheItemOnTheGround is the other half of
// atomicity: a move that cannot complete does not half-complete.
func TestAFullInventoryRefusesAndKeepsTheItemOnTheGround(t *testing.T) {
	s := NewMemoryStore()
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

// TestTakingForAnUnknownPlayerFails guards the invariant addPlayer keeps. It is
// a broken caller rather than a game condition, so it must be loud.
func TestTakingForAnUnknownPlayerFails(t *testing.T) {
	s := NewMemoryStore()
	item := s.SpawnGroundItem(KindAcorn, 0, 0)

	if _, err := s.TakeGroundItem(item.ID, 42); !errors.Is(err, ErrNoSuchPlayer) {
		t.Fatalf("take for a player with no inventory returned %v, want ErrNoSuchPlayer", err)
	}
	if _, onGround := s.GroundItem(item.ID); !onGround {
		t.Fatal("a take for an unknown player removed the item from the ground")
	}
}

// TestGroundItemsAreListedOldestFirst is what makes two identical runs produce
// identical welcomes. Go randomises map iteration, so the order has to come
// from somewhere else.
func TestGroundItemsAreListedOldestFirst(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)

	for i := range 6 {
		s.SpawnGroundItem(KindAcorn, float64(i), 0)
	}
	// Take one from the middle: the survivors must keep their order, and the
	// hole must not become a gap in the ids the list reports.
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

// TestRemovingAPlayerTakesTheirItemsWithThem records the M1 decision, so that
// changing it later is a decision rather than an accident. There is no
// persistence and no drop-on-logout.
func TestRemovingAPlayerTakesTheirItemsWithThem(t *testing.T) {
	s := NewMemoryStore()
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
	// Removing twice is how a connection that dies in two ways is retired.
	s.RemovePlayer(1)
}
