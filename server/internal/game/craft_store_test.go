package game

import (
	"errors"
	"testing"
)

func TestCraftLogsToSticksIsOneMove(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindLogs); err != nil {
		t.Fatalf("seeding logs: %v", err)
	}

	done, err := s.CraftInventorySlot(1, 0, KindLogs, KindSticks)
	if err != nil {
		t.Fatalf("craft: %v", err)
	}
	if done.From != 0 || done.Into != 0 || done.Consume != KindLogs || done.Produce != KindSticks {
		t.Fatalf("crafted %+v, want from=0 into=0 logs→sticks", done)
	}
	got := s.Inventory(1)
	if len(got) != 1 || got[0].Index != 0 || got[0].Kind != KindSticks {
		t.Fatalf("inventory %+v, want one sticks in slot 0", got)
	}
}

func TestCraftRefusesWrongKindWithoutMutating(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindAcorn); err != nil {
		t.Fatalf("seeding acorn: %v", err)
	}

	if _, err := s.CraftInventorySlot(1, 0, KindLogs, KindSticks); !errors.Is(err, ErrNoRecipe) {
		t.Fatalf("craft returned %v, want ErrNoRecipe", err)
	}
	got := s.Inventory(1)
	if len(got) != 1 || got[0].Kind != KindAcorn {
		t.Fatalf("inventory %+v after refuse, want the acorn unchanged", got)
	}
}

func TestCraftRefusesAFullBagWithoutMutating(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindLogs); err != nil {
		t.Fatalf("seeding logs: %v", err)
	}
	for i := 1; i < InventorySize; i++ {
		if _, err := s.SpawnInventoryItem(1, KindAcorn); err != nil {
			t.Fatalf("filling slot %d: %v", i, err)
		}
	}

	if _, err := s.CraftInventorySlot(1, 0, KindLogs, KindSticks); !errors.Is(err, ErrInventoryFull) {
		t.Fatalf("craft returned %v, want ErrInventoryFull", err)
	}
	got := s.Inventory(1)
	if len(got) != InventorySize {
		t.Fatalf("inventory holds %d after refuse, want %d", len(got), InventorySize)
	}
	if got[0].Kind != KindLogs {
		t.Fatalf("slot 0 holds %q after refuse, want logs", got[0].Kind)
	}
}

func TestCraftFillsTheLowestFreeSlotAfterConsume(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindAcorn); err != nil {
		t.Fatalf("seeding acorn: %v", err)
	}
	if _, err := s.SpawnInventoryItem(1, KindLogs); err != nil {
		t.Fatalf("seeding logs: %v", err)
	}

	done, err := s.CraftInventorySlot(1, 1, KindLogs, KindSticks)
	if err != nil {
		t.Fatalf("craft: %v", err)
	}
	if done.Into != 1 {
		t.Fatalf("sticks landed in slot %d, want 1 (emptied ingredient, lowest free after consume)", done.Into)
	}
}
