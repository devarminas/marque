package game

import (
	"errors"
	"slices"
	"testing"
)

func TestDeliverStickForMinerRewardsIsOneMove(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindStick); err != nil {
		t.Fatalf("seeding stick: %v", err)
	}
	rewards := []string{
		"prospector_jacket",
		"prospector_boots",
		"prospector_helm",
		"prospector_legs",
		KindPickaxe,
	}

	done, err := s.DeliverInventorySlot(1, 0, KindStick, rewards)
	if err != nil {
		t.Fatalf("deliver: %v", err)
	}
	if done.From != 0 || done.Consume != KindStick {
		t.Fatalf("delivered %+v", done)
	}
	if len(done.Rewards) != len(rewards) {
		t.Fatalf("reward slots %d, want %d", len(done.Rewards), len(rewards))
	}
	got := s.Inventory(1)
	if len(got) != len(rewards) {
		t.Fatalf("inventory %+v, want %d rewards", got, len(rewards))
	}
	kinds := make([]string, len(got))
	for i, slot := range got {
		kinds[i] = slot.Kind
	}
	if !slices.Equal(kinds, rewards) {
		t.Fatalf("kinds=%v want %v", kinds, rewards)
	}
	if worn := s.Worn(1); len(worn) != 0 {
		t.Fatalf("worn %+v, want bag-only rewards", worn)
	}
}

func TestDeliverRefusesWrongKindWithoutMutating(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindAcorn); err != nil {
		t.Fatalf("seeding acorn: %v", err)
	}

	if _, err := s.DeliverInventorySlot(1, 0, KindStick, []string{KindPickaxe}); !errors.Is(err, ErrWrongKind) {
		t.Fatalf("deliver returned %v, want ErrWrongKind", err)
	}
	got := s.Inventory(1)
	if len(got) != 1 || got[0].Kind != KindAcorn {
		t.Fatalf("inventory %+v after refuse, want the acorn unchanged", got)
	}
}

func TestDeliverRefusesFullBagWithoutMutating(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindStick); err != nil {
		t.Fatalf("seeding stick: %v", err)
	}
	for i := 1; i < InventorySize; i++ {
		if _, err := s.SpawnInventoryItem(1, KindAcorn); err != nil {
			t.Fatalf("filling slot %d: %v", i, err)
		}
	}
	rewards := []string{
		"prospector_jacket",
		"prospector_boots",
		"prospector_helm",
		"prospector_legs",
		KindPickaxe,
	}

	if _, err := s.DeliverInventorySlot(1, 0, KindStick, rewards); !errors.Is(err, ErrInventoryFull) {
		t.Fatalf("deliver returned %v, want ErrInventoryFull", err)
	}
	got := s.Inventory(1)
	if len(got) != InventorySize {
		t.Fatalf("inventory holds %d after refuse, want %d", len(got), InventorySize)
	}
	if got[0].Kind != KindStick {
		t.Fatalf("slot 0 holds %q after refuse, want stick", got[0].Kind)
	}
}

func TestDeliverRefusesEmptySlot(t *testing.T) {
	s := NewMemoryStore(NoWearables)
	s.AddPlayer(1)
	if _, err := s.DeliverInventorySlot(1, 0, KindStick, []string{KindPickaxe}); !errors.Is(err, ErrEmptySlot) {
		t.Fatalf("deliver returned %v, want ErrEmptySlot", err)
	}
}
