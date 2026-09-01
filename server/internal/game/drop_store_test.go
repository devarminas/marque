package game

// The reverse of store_test.go's take: DropInventorySlot, the one call that
// moves an item out of a slot and onto the ground. In-package for the same
// reason, and every test here is a sentence about the Store interface that a
// Postgres implementation will have to reproduce.

import (
	"errors"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

// TestDropIsOneMove is TestTakeIsOneMove in the other direction, and the
// interface's reason to exist read backwards. One call moves the item out of
// the slot and onto the ground; afterwards it is in exactly one of the two
// places, never both and never neither.
func TestDropIsOneMove(t *testing.T) {
	s := NewMemoryStore()
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

// TestADroppedItemGetsANewId is forced by the data model rather than chosen. An
// inventory holds kinds, not item ids, so the id an item had before it was
// picked up is already unrecoverable by the time it is dropped -- and ids are
// never reused within a process, so it could not come back even if it were.
//
// It matters on the wire: a client that cached the old id was told that one
// despawned, and must be told about the new body under a name it has never
// heard.
func TestADroppedItemGetsANewId(t *testing.T) {
	s := NewMemoryStore()
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

// TestTakeAndDropRoundTripReturnsTheStoreToItsShape is the unit's reason to
// exist at the layer that decides it: pickup's reverse transaction leaves one
// item on the ground and an empty inventory, exactly as it started, and the
// only difference is the id.
func TestTakeAndDropRoundTripReturnsTheStoreToItsShape(t *testing.T) {
	s := NewMemoryStore()
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

// TestDroppingAnEmptySlotChangesNothing is the other half of atomicity, the
// same one TestAFullInventoryRefusesAndKeepsTheItemOnTheGround holds for take:
// a move that cannot complete does not half-complete.
func TestDroppingAnEmptySlotChangesNothing(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	item := s.SpawnGroundItem(KindAcorn, 0, 0)
	if _, err := s.TakeGroundItem(item.ID, 1); err != nil {
		t.Fatalf("taking item %d: %v", item.ID, err)
	}

	// Slot 0 holds the acorn; every other slot is empty.
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

// TestDroppingAnIndexOutsideTheInventoryChangesNothing. No index in that range
// was ever legal, so this is a broken client rather than a stale one, and it
// gets its own error for that reason.
func TestDroppingAnIndexOutsideTheInventoryChangesNothing(t *testing.T) {
	for _, slot := range []int{-1, InventorySize, InventorySize + 1000} {
		s := NewMemoryStore()
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

// TestDroppingForAnUnknownPlayerFails. Reaching it means the caller has a
// player the store has never heard of, which is a broken invariant rather than
// a condition; the store still refuses rather than panicking, because the
// interface answers questions and the caller decides what is fatal.
func TestDroppingForAnUnknownPlayerFails(t *testing.T) {
	s := NewMemoryStore()

	if _, err := s.DropInventorySlot(mnet.PlayerID(42), 0, 0, 0); !errors.Is(err, ErrNoSuchPlayer) {
		t.Fatalf("dropping for a player with no inventory returned %v, want ErrNoSuchPlayer", err)
	}
	if items := s.GroundItems(); len(items) != 0 {
		t.Fatalf("a drop for an unknown player put %+v on the ground", items)
	}
}

// TestADroppedItemJoinsTheBackOfTheGroundOrder keeps welcome's item list
// deterministic once drops exist. GroundItems is ordered by when items entered
// the world, and a dropped item entered now.
func TestADroppedItemJoinsTheBackOfTheGroundOrder(t *testing.T) {
	s := NewMemoryStore()
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
