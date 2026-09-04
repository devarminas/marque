package game

// The two Store transactions M3a adds, at the layer that decides them.
// In-package for store_test.go's and drop_store_test.go's reason: every test
// here is a sentence about the Store interface that a Postgres implementation
// will have to reproduce.

import (
	"errors"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

// fill puts a kind in every free bag slot, so a test can reach the full-bag
// branch without twenty-eight lines saying so.
func fill(t *testing.T, s Store, player mnet.PlayerID, kind string) {
	t.Helper()
	for {
		if _, err := s.SpawnInventoryItem(player, kind); err != nil {
			if errors.Is(err, ErrInventoryFull) {
				return
			}
			t.Fatalf("filling player %d with %q: %v", player, kind, err)
		}
	}
}

// wornKindIn reports what a player has in one worn slot, read back through the
// interface rather than out of the implementation.
func wornKindIn(s Store, player mnet.PlayerID, slot mnet.EquipSlot) (string, bool) {
	for _, w := range s.Worn(player) {
		if w.Slot == slot {
			return w.Kind, true
		}
	}
	return "", false
}

// TestWornSlotsAndTheKindTableAgree pins the two tables against each other. A
// kind mapped to a slot name that is not in WornSlots would be equippable and
// then impossible to take off, because unequip refuses a name the list does not
// have.
func TestWornSlotsAndTheKindTableAgree(t *testing.T) {
	for kind, slot := range wornSlotOf {
		if !wornSlotExists(slot) {
			t.Errorf("kind %q equips into %q, which is not in WornSlots %v: it could be worn and never removed", kind, slot, WornSlots)
		}
	}
	seen := make(map[mnet.EquipSlot]bool, len(WornSlots))
	for _, slot := range WornSlots {
		if seen[slot] {
			t.Errorf("WornSlots lists %q twice: %v", slot, WornSlots)
		}
		seen[slot] = true
	}
}

// TestEquipIsOneMove is the interface's reason to exist, the same sentence
// TestTakeIsOneMove and TestDropIsOneMove say about the ground. One call moves
// the item out of the bag and into the worn slot; afterwards it is in exactly
// one of the two places, never both and never neither.
func TestEquipIsOneMove(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(7)
	if _, err := s.SpawnInventoryItem(7, KindAxe); err != nil {
		t.Fatalf("seeding an axe: %v", err)
	}

	done, err := s.EquipInventorySlot(7, 0)
	if err != nil {
		t.Fatalf("equipping slot 0: %v", err)
	}

	want := Equipped{Worn: SlotWeapon, Kind: KindAxe, Bag: 0}
	if done != want {
		t.Fatalf("the equip reported %+v, want %+v", done, want)
	}
	if got := s.Inventory(7); len(got) != 0 {
		t.Fatalf("the bag still holds %+v after the axe left it: the axe is in both places at once", got)
	}
	kind, wearing := wornKindIn(s, 7, SlotWeapon)
	if !wearing {
		t.Fatal("the axe left the bag and never reached the worn slot")
	}
	if kind != KindAxe {
		t.Fatalf("the worn slot holds %q, want %q", kind, KindAxe)
	}
}

// TestEquipNeverTouchesTheGround. The bag and the worn slots are the only two
// containers an equip addresses, and an implementation that routed through the
// ground would mint an item id and broadcast a body to every other client.
func TestEquipNeverTouchesTheGround(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindAxe); err != nil {
		t.Fatalf("seeding an axe: %v", err)
	}

	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping slot 0: %v", err)
	}
	if _, err := s.UnequipWornSlot(1, SlotWeapon); err != nil {
		t.Fatalf("unequipping: %v", err)
	}

	if items := s.GroundItems(); len(items) != 0 {
		t.Fatalf("a round trip through the worn slot put %+v on the ground", items)
	}
}

// TestSpawnInventoryItemMintsNoItemId is what makes the join kit a bag item
// rather than a world item. An inventory holds kinds, so an item that was never
// on the ground has nothing an id could name, and burning one would make the
// next ground item's id unpredictable to every test and launch script.
func TestSpawnInventoryItemMintsNoItemId(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)

	if _, err := s.SpawnInventoryItem(1, KindAxe); err != nil {
		t.Fatalf("seeding an axe: %v", err)
	}

	item := s.SpawnGroundItem(KindAcorn, 0, 0)
	if item.ID != 1 {
		t.Fatalf("the first ground item is id %d, want 1: the bag item consumed an id it has no use for", item.ID)
	}
}

// TestSpawnInventoryItemFillsTheLowestFreeSlot, which is what makes a join kit
// land in a predictable order and RuneScape's rule for every path into the bag.
func TestSpawnInventoryItemFillsTheLowestFreeSlot(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)

	for i := range 3 {
		slot, err := s.SpawnInventoryItem(1, KindAcorn)
		if err != nil {
			t.Fatalf("seeding item %d: %v", i, err)
		}
		if slot.Index != i {
			t.Fatalf("item %d landed in slot %d, want %d", i, slot.Index, i)
		}
	}
}

// TestSpawnInventoryItemRefusesAFullBag, which is the branch the join kit must
// never reach and which the world panics on if it does.
func TestSpawnInventoryItemRefusesAFullBag(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	fill(t, s, 1, KindAcorn)

	if _, err := s.SpawnInventoryItem(1, KindAxe); !errors.Is(err, ErrInventoryFull) {
		t.Fatalf("seeding into a full bag returned %v, want ErrInventoryFull", err)
	}
	if got := s.Inventory(1); len(got) != InventorySize {
		t.Fatalf("the bag holds %d slots after a refused seed, want the full %d", len(got), InventorySize)
	}
}

// TestEquipSwapsThroughTheBagSlotItVacated is RuneScape's answer to equipping
// onto an occupied slot, and it is the reason equip has no room question: the
// slot the new item leaves is the one the old item lands in, so a swap cannot
// fail for want of space even in a completely full bag.
func TestEquipSwapsThroughTheBagSlotItVacated(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindAxe); err != nil {
		t.Fatalf("seeding the first axe: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping the first axe: %v", err)
	}
	fill(t, s, 1, KindAcorn)
	if _, err := s.SpawnInventoryItem(1, KindAxe); !errors.Is(err, ErrInventoryFull) {
		t.Fatalf("the bag is not full, so the swap below proves nothing: %v", err)
	}

	// Slot 0 is an acorn and slots 1 upward are acorns too, so put the second
	// axe somewhere known by taking one off the ground.
	ground := s.SpawnGroundItem(KindAxe, 0, 0)
	if _, err := s.DropInventorySlot(1, 5, 0, 0); err != nil {
		t.Fatalf("making room in slot 5: %v", err)
	}
	slot, err := s.TakeGroundItem(ground.ID, 1)
	if err != nil {
		t.Fatalf("taking the second axe: %v", err)
	}

	done, err := s.EquipInventorySlot(1, slot.Index)
	if err != nil {
		t.Fatalf("equipping into an occupied worn slot with a full bag: %v", err)
	}

	if done.Displaced != KindAxe {
		t.Fatalf("the swap displaced %q, want the %q that was worn", done.Displaced, KindAxe)
	}
	if done.Bag != slot.Index {
		t.Fatalf("the swap reports bag slot %d, want %d, the one the new axe left", done.Bag, slot.Index)
	}
	if got := s.Inventory(1); len(got) != InventorySize {
		t.Fatalf("the bag holds %d slots after a swap, want the same full %d: a swap moves two items and creates none", len(got), InventorySize)
	}
	if kind, _ := wornKindIn(s, 1, SlotWeapon); kind != KindAxe {
		t.Fatalf("the worn slot holds %q after the swap, want %q", kind, KindAxe)
	}
	axes := 0
	for _, held := range s.Inventory(1) {
		if held.Kind == KindAxe {
			axes++
		}
	}
	if axes != 1 {
		t.Fatalf("the bag holds %d axes after the swap, want exactly the one displaced", axes)
	}
}

// TestUnequipIsOneMove is TestEquipIsOneMove in the other direction, which is
// what makes it the atomicity test rather than a second happy path.
func TestUnequipIsOneMove(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindAxe); err != nil {
		t.Fatalf("seeding an axe: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping: %v", err)
	}

	done, err := s.UnequipWornSlot(1, SlotWeapon)
	if err != nil {
		t.Fatalf("unequipping: %v", err)
	}

	want := Unequipped{Worn: SlotWeapon, Kind: KindAxe, Bag: 0}
	if done != want {
		t.Fatalf("the unequip reported %+v, want %+v", done, want)
	}
	if _, wearing := wornKindIn(s, 1, SlotWeapon); wearing {
		t.Fatal("the worn slot still holds the axe after it left")
	}
	held := s.Inventory(1)
	if len(held) != 1 || held[0].Kind != KindAxe || held[0].Index != 0 {
		t.Fatalf("the bag holds %+v, want the one axe back in slot 0", held)
	}
}

// TestUnequipFillsTheLowestFreeSlot, not the slot the item was equipped from.
// The store does not remember where an item came from, and nothing should make
// it start.
func TestUnequipFillsTheLowestFreeSlot(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	for _, kind := range []string{KindAcorn, KindAcorn, KindAxe} {
		if _, err := s.SpawnInventoryItem(1, kind); err != nil {
			t.Fatalf("seeding %q: %v", kind, err)
		}
	}
	if _, err := s.EquipInventorySlot(1, 2); err != nil {
		t.Fatalf("equipping slot 2: %v", err)
	}
	if _, err := s.DropInventorySlot(1, 0, 0, 0); err != nil {
		t.Fatalf("emptying slot 0: %v", err)
	}

	done, err := s.UnequipWornSlot(1, SlotWeapon)
	if err != nil {
		t.Fatalf("unequipping: %v", err)
	}

	if done.Bag != 0 {
		t.Fatalf("the axe came back to slot %d, want slot 0, the lowest free one rather than the 2 it left", done.Bag)
	}
}

// TestARefusedEquipChangesNothing is atomicity's other half, the one
// TestDroppingAnEmptySlotChangesNothing holds for drop: a move that cannot
// complete does not half-complete.
func TestARefusedEquipChangesNothing(t *testing.T) {
	cases := []struct {
		name string
		slot int
		want error
	}{
		{"below the first slot", -1, ErrNoSuchSlot},
		{"one past the last slot", InventorySize, ErrNoSuchSlot},
		{"far outside the bag", 1 << 20, ErrNoSuchSlot},
		{"a legal slot holding nothing", 3, ErrEmptySlot},
		{"a kind that belongs to no worn slot", 1, ErrNotEquippable},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := NewMemoryStore()
			s.AddPlayer(1)
			for _, kind := range []string{KindAxe, KindAcorn} {
				if _, err := s.SpawnInventoryItem(1, kind); err != nil {
					t.Fatalf("seeding %q: %v", kind, err)
				}
			}

			if _, err := s.EquipInventorySlot(1, tc.slot); !errors.Is(err, tc.want) {
				t.Fatalf("equipping slot %d returned %v, want %v", tc.slot, err, tc.want)
			}
			if got := s.Inventory(1); len(got) != 2 || got[0].Kind != KindAxe || got[1].Kind != KindAcorn {
				t.Fatalf("a refused equip left the bag as %+v, want the axe and the acorn untouched", got)
			}
			if worn := s.Worn(1); len(worn) != 0 {
				t.Fatalf("a refused equip put %+v in a worn slot", worn)
			}
			if items := s.GroundItems(); len(items) != 0 {
				t.Fatalf("a refused equip put %+v on the ground", items)
			}
		})
	}
}

// TestARefusedUnequipChangesNothing, and the full-bag case is the one that
// matters: the alternative to refusing is the store deciding on its own to put
// the item somewhere the player did not ask for.
func TestARefusedUnequipChangesNothing(t *testing.T) {
	cases := []struct {
		name string
		slot mnet.EquipSlot
		full bool
		want error
	}{
		{"a slot this server does not have", "helmet", false, ErrNoSuchWornSlot},
		{"a name that is no name at all", "", false, ErrNoSuchWornSlot},
		{"a full bag", SlotWeapon, true, ErrInventoryFull},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := NewMemoryStore()
			s.AddPlayer(1)
			if _, err := s.SpawnInventoryItem(1, KindAxe); err != nil {
				t.Fatalf("seeding an axe: %v", err)
			}
			if _, err := s.EquipInventorySlot(1, 0); err != nil {
				t.Fatalf("equipping: %v", err)
			}
			if tc.full {
				fill(t, s, 1, KindAcorn)
			}

			if _, err := s.UnequipWornSlot(1, tc.slot); !errors.Is(err, tc.want) {
				t.Fatalf("unequipping %q returned %v, want %v", tc.slot, err, tc.want)
			}
			if kind, wearing := wornKindIn(s, 1, SlotWeapon); !wearing || kind != KindAxe {
				t.Fatalf("a refused unequip left the worn slot as %+v, want the axe still on", s.Worn(1))
			}
			if items := s.GroundItems(); len(items) != 0 {
				t.Fatalf("a refused unequip put %+v on the ground; nothing is ever silently dropped", items)
			}
			axes := 0
			for _, held := range s.Inventory(1) {
				if held.Kind == KindAxe {
					axes++
				}
			}
			if axes != 0 {
				t.Fatalf("a refused unequip put %d axes in the bag while one is still worn", axes)
			}
		})
	}
}

// TestUnequippingAnEmptyWornSlotIsItsOwnRefusal. A name this server has that
// holds nothing is a stale client; a name it does not have is a broken one, and
// they get different errors for drop's reason.
func TestUnequippingAnEmptyWornSlotIsItsOwnRefusal(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)

	if _, err := s.UnequipWornSlot(1, SlotWeapon); !errors.Is(err, ErrEmptyWornSlot) {
		t.Fatalf("unequipping an empty worn slot returned %v, want ErrEmptyWornSlot", err)
	}
}

// TestEquipAndUnequipForAnUnknownPlayerFail. Reaching either means the caller
// has a player the store has never heard of; the store refuses rather than
// panicking, because the interface answers questions and the caller decides
// what is fatal.
func TestEquipAndUnequipForAnUnknownPlayerFail(t *testing.T) {
	s := NewMemoryStore()

	if _, err := s.EquipInventorySlot(42, 0); !errors.Is(err, ErrNoSuchPlayer) {
		t.Errorf("equipping for an unknown player returned %v, want ErrNoSuchPlayer", err)
	}
	if _, err := s.UnequipWornSlot(42, SlotWeapon); !errors.Is(err, ErrNoSuchPlayer) {
		t.Errorf("unequipping for an unknown player returned %v, want ErrNoSuchPlayer", err)
	}
	if _, err := s.SpawnInventoryItem(42, KindAxe); !errors.Is(err, ErrNoSuchPlayer) {
		t.Errorf("seeding for an unknown player returned %v, want ErrNoSuchPlayer", err)
	}
	if worn := s.Worn(42); worn != nil {
		t.Errorf("an unknown player is wearing %+v, want nil", worn)
	}
}

// TestRetiringAPlayerForgetsWhatItWore. Worn equipment dies with the player, as
// the bag does, and a worn slot that outlived its owner would be handed to
// whoever was issued that id next if ids were ever reused.
func TestRetiringAPlayerForgetsWhatItWore(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindAxe); err != nil {
		t.Fatalf("seeding an axe: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping: %v", err)
	}

	s.RemovePlayer(1)

	if worn := s.Worn(1); worn != nil {
		t.Fatalf("a retired player is still wearing %+v", worn)
	}
	s.AddPlayer(1)
	if worn := s.Worn(1); len(worn) != 0 {
		t.Fatalf("a rejoining player inherited %+v", worn)
	}
}

// TestWornSlotsAreNotSharedBetweenPlayers, which a map keyed by slot name and
// shared by accident would break silently: everybody would be wearing whatever
// the last person equipped.
func TestWornSlotsAreNotSharedBetweenPlayers(t *testing.T) {
	s := NewMemoryStore()
	s.AddPlayer(1)
	s.AddPlayer(2)
	if _, err := s.SpawnInventoryItem(1, KindAxe); err != nil {
		t.Fatalf("seeding an axe: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping: %v", err)
	}

	if worn := s.Worn(2); len(worn) != 0 {
		t.Fatalf("player 2 is wearing %+v after player 1 equipped", worn)
	}
	if held := s.Inventory(2); len(held) != 0 {
		t.Fatalf("player 2 holds %+v", held)
	}
}
