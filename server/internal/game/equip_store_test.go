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
	for kind, slots := range testWearables(t) {
		for _, slot := range slots {
			if !wornSlotExists(slot) {
				t.Errorf("kind %q equips into %q, which is not in WornSlots %v: it could be worn and never removed", kind, slot, WornSlots)
			}
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
	s := newStore(t)
	s.AddPlayer(7)
	if _, err := s.SpawnInventoryItem(7, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}

	done, err := s.EquipInventorySlot(7, 0)
	if err != nil {
		t.Fatalf("equipping slot 0: %v", err)
	}

	want := Equipped{Worn: SlotRightHand, Kind: KindSword, Bag: 0}
	if done != want {
		t.Fatalf("the equip reported %+v, want %+v", done, want)
	}
	if got := s.Inventory(7); len(got) != 0 {
		t.Fatalf("the bag still holds %+v after the sword left it: the sword is in both places at once", got)
	}
	kind, wearing := wornKindIn(s, 7, SlotRightHand)
	if !wearing {
		t.Fatal("the sword left the bag and never reached the worn slot")
	}
	if kind != KindSword {
		t.Fatalf("the worn slot holds %q, want %q", kind, KindSword)
	}
}

// TestEquipNeverTouchesTheGround. The bag and the worn slots are the only two
// containers an equip addresses, and an implementation that routed through the
// ground would mint an item id and broadcast a body to every other client.
func TestEquipNeverTouchesTheGround(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}

	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping slot 0: %v", err)
	}
	if _, err := s.UnequipWornSlot(1, SlotRightHand); err != nil {
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
	s := newStore(t)
	s.AddPlayer(1)

	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}

	item := s.SpawnGroundItem(KindAcorn, 0, 0)
	if item.ID != 1 {
		t.Fatalf("the first ground item is id %d, want 1: the bag item consumed an id it has no use for", item.ID)
	}
}

// TestSpawnInventoryItemFillsTheLowestFreeSlot, which is what makes a join kit
// land in a predictable order and RuneScape's rule for every path into the bag.
func TestSpawnInventoryItemFillsTheLowestFreeSlot(t *testing.T) {
	s := newStore(t)
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
	s := newStore(t)
	s.AddPlayer(1)
	fill(t, s, 1, KindAcorn)

	if _, err := s.SpawnInventoryItem(1, KindSword); !errors.Is(err, ErrInventoryFull) {
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
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding the first axe: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping the first axe: %v", err)
	}
	fill(t, s, 1, KindAcorn)
	if _, err := s.SpawnInventoryItem(1, KindSword); !errors.Is(err, ErrInventoryFull) {
		t.Fatalf("the bag is not full, so the swap below proves nothing: %v", err)
	}

	// Slot 0 is an acorn and slots 1 upward are acorns too, so put the second
	// axe somewhere known by taking one off the ground.
	ground := s.SpawnGroundItem(KindSword, 0, 0)
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

	if done.Displaced != KindSword {
		t.Fatalf("the swap displaced %q, want the %q that was worn", done.Displaced, KindSword)
	}
	if done.Bag != slot.Index {
		t.Fatalf("the swap reports bag slot %d, want %d, the one the new axe left", done.Bag, slot.Index)
	}
	if got := s.Inventory(1); len(got) != InventorySize {
		t.Fatalf("the bag holds %d slots after a swap, want the same full %d: a swap moves two items and creates none", len(got), InventorySize)
	}
	if kind, _ := wornKindIn(s, 1, SlotRightHand); kind != KindSword {
		t.Fatalf("the worn slot holds %q after the swap, want %q", kind, KindSword)
	}
	axes := 0
	for _, held := range s.Inventory(1) {
		if held.Kind == KindSword {
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
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping: %v", err)
	}

	done, err := s.UnequipWornSlot(1, SlotRightHand)
	if err != nil {
		t.Fatalf("unequipping: %v", err)
	}

	want := Unequipped{Worn: SlotRightHand, Kind: KindSword, Bag: 0}
	if done != want {
		t.Fatalf("the unequip reported %+v, want %+v", done, want)
	}
	if _, wearing := wornKindIn(s, 1, SlotRightHand); wearing {
		t.Fatal("the worn slot still holds the sword after it left")
	}
	held := s.Inventory(1)
	if len(held) != 1 || held[0].Kind != KindSword || held[0].Index != 0 {
		t.Fatalf("the bag holds %+v, want the one axe back in slot 0", held)
	}
}

// TestUnequipFillsTheLowestFreeSlot, not the slot the item was equipped from.
// The store does not remember where an item came from, and nothing should make
// it start.
func TestUnequipFillsTheLowestFreeSlot(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	for _, kind := range []string{KindAcorn, KindAcorn, KindSword} {
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

	done, err := s.UnequipWornSlot(1, SlotRightHand)
	if err != nil {
		t.Fatalf("unequipping: %v", err)
	}

	if done.Bag != 0 {
		t.Fatalf("the sword came back to slot %d, want slot 0, the lowest free one rather than the 2 it left", done.Bag)
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
			s := newStore(t)
			s.AddPlayer(1)
			for _, kind := range []string{KindSword, KindAcorn} {
				if _, err := s.SpawnInventoryItem(1, kind); err != nil {
					t.Fatalf("seeding %q: %v", kind, err)
				}
			}

			if _, err := s.EquipInventorySlot(1, tc.slot); !errors.Is(err, tc.want) {
				t.Fatalf("equipping slot %d returned %v, want %v", tc.slot, err, tc.want)
			}
			if got := s.Inventory(1); len(got) != 2 || got[0].Kind != KindSword || got[1].Kind != KindAcorn {
				t.Fatalf("a refused equip left the bag as %+v, want the sword and the acorn untouched", got)
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
		{"a slot this server does not have", "cape", false, ErrNoSuchWornSlot},
		{"a name that is no name at all", "", false, ErrNoSuchWornSlot},
		{"a full bag", SlotRightHand, true, ErrInventoryFull},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newStore(t)
			s.AddPlayer(1)
			if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
				t.Fatalf("seeding a sword: %v", err)
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
			if kind, wearing := wornKindIn(s, 1, SlotRightHand); !wearing || kind != KindSword {
				t.Fatalf("a refused unequip left the worn slot as %+v, want the sword still on", s.Worn(1))
			}
			if items := s.GroundItems(); len(items) != 0 {
				t.Fatalf("a refused unequip put %+v on the ground; nothing is ever silently dropped", items)
			}
			axes := 0
			for _, held := range s.Inventory(1) {
				if held.Kind == KindSword {
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
	s := newStore(t)
	s.AddPlayer(1)

	if _, err := s.UnequipWornSlot(1, SlotRightHand); !errors.Is(err, ErrEmptyWornSlot) {
		t.Fatalf("unequipping an empty worn slot returned %v, want ErrEmptyWornSlot", err)
	}
}

// TestEquipAndUnequipForAnUnknownPlayerFail. Reaching either means the caller
// has a player the store has never heard of; the store refuses rather than
// panicking, because the interface answers questions and the caller decides
// what is fatal.
func TestEquipAndUnequipForAnUnknownPlayerFail(t *testing.T) {
	s := newStore(t)

	if _, err := s.EquipInventorySlot(42, 0); !errors.Is(err, ErrNoSuchPlayer) {
		t.Errorf("equipping for an unknown player returned %v, want ErrNoSuchPlayer", err)
	}
	if _, err := s.UnequipWornSlot(42, SlotRightHand); !errors.Is(err, ErrNoSuchPlayer) {
		t.Errorf("unequipping for an unknown player returned %v, want ErrNoSuchPlayer", err)
	}
	if _, err := s.SpawnInventoryItem(42, KindSword); !errors.Is(err, ErrNoSuchPlayer) {
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
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
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
	s := newStore(t)
	s.AddPlayer(1)
	s.AddPlayer(2)
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
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

// wornKindsIn reports every worn slot a player has a given kind in, read back
// through the interface.
func wornKindsIn(s Store, player mnet.PlayerID, kind string) []mnet.EquipSlot {
	var slots []mnet.EquipSlot
	for _, w := range s.Worn(player) {
		if w.Kind == kind {
			slots = append(slots, w.Slot)
		}
	}
	return slots
}

// TestAOneHandedKindOccupiesOneHand: the right hand, so the left hand stays
// free for a shield or a second one-handed tool. M7b, AC2.
func TestAOneHandedKindOccupiesOneHand(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}

	done, err := s.EquipInventorySlot(1, 0)
	if err != nil {
		t.Fatalf("equipping a sword: %v", err)
	}

	want := Equipped{Worn: SlotRightHand, Kind: KindSword, Bag: 0}
	if done != want {
		t.Fatalf("the equip reported %+v, want %+v", done, want)
	}
	if kind, wearing := wornKindIn(s, 1, SlotRightHand); !wearing || kind != KindSword {
		t.Fatalf("right hand holds %q in %+v, want the sword there", kind, s.Worn(1))
	}
	if _, wearing := wornKindIn(s, 1, SlotLeftHand); wearing {
		t.Fatalf("left hand holds %+v, want it free for a second one-handed tool", s.Worn(1))
	}
}

// TestATwoHandedKindOccupiesBothHands. The kind fills left and right hand, the
// restatement shows both, and there is no point where one hand has it and the
// other does not. M7b, AC1.
func TestATwoHandedKindOccupiesBothHands(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindStaff); err != nil {
		t.Fatalf("seeding a staff: %v", err)
	}

	done, err := s.EquipInventorySlot(1, 0)
	if err != nil {
		t.Fatalf("equipping a staff: %v", err)
	}

	want := Equipped{Worn: SlotLeftHand, Kind: KindStaff, Bag: 0}
	if done != want {
		t.Fatalf("the equip reported %+v, want %+v", done, want)
	}
	got := wornKindsIn(s, 1, KindStaff)
	if len(got) != 2 {
		t.Fatalf("the staff is in %v, want both hands", got)
	}
	for _, slot := range []mnet.EquipSlot{SlotLeftHand, SlotRightHand} {
		found := false
		for _, s := range got {
			if s == slot {
				found = true
			}
		}
		if !found {
			t.Fatalf("the staff is missing from %q: held in %v", slot, got)
		}
	}
}

// TestUnequippingAHandOfATwoHandedKindClearsBothHands, because a hand cannot
// keep half of a two-handed tool, and the bag receives the kind once. M7b, AC4.
func TestUnequippingAHandOfATwoHandedKindClearsBothHands(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindBow); err != nil {
		t.Fatalf("seeding a bow: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping the bow: %v", err)
	}

	done, err := s.UnequipWornSlot(1, SlotLeftHand)
	if err != nil {
		t.Fatalf("unequipping the left hand: %v", err)
	}

	want := Unequipped{Worn: SlotLeftHand, Kind: KindBow, Bag: 0}
	if done != want {
		t.Fatalf("the unequip reported %+v, want %+v", done, want)
	}
	if worn := s.Worn(1); len(worn) != 0 {
		t.Fatalf("clearing one hand left %+v: a two-handed kind must clear both", worn)
	}
	if held := s.Inventory(1); len(held) != 1 || held[0].Kind != KindBow {
		t.Fatalf("the bag holds %+v, want the one bow back", held)
	}
}

// TestUnequippingAHandOfATwoHandedKindWithAFullBagRefuses. The bag must have
// room for the kind before either hand is cleared, so a full bag leaves both
// hands wearing it and nothing is lost. M7b, AC4.
func TestUnequippingAHandOfATwoHandedKindWithAFullBagRefuses(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindStaff); err != nil {
		t.Fatalf("seeding a staff: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping the staff: %v", err)
	}
	fill(t, s, 1, KindAcorn)

	if _, err := s.UnequipWornSlot(1, SlotRightHand); !errors.Is(err, ErrInventoryFull) {
		t.Fatalf("unequipping with a full bag returned %v, want ErrInventoryFull", err)
	}
	if got := wornKindsIn(s, 1, KindStaff); len(got) != 2 {
		t.Fatalf("a refused unequip left the staff in %v, want both hands still wearing it", got)
	}
}

// TestEquippingAOneHandedWeaponOntoATwoHandedToolSwaps, which is the slot
// exclusivity test: the new kind's handedness decides what the old item
// vacates, so the free hand the old kind was holding opens up. M7b, AC3.
func TestEquippingAOneHandedWeaponOntoATwoHandedToolSwaps(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindStaff); err != nil {
		t.Fatalf("seeding a staff: %v", err)
	}
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping the staff: %v", err)
	}

	done, err := s.EquipInventorySlot(1, 1)
	if err != nil {
		t.Fatalf("equipping the sword onto the staff: %v", err)
	}

	if done.Displaced != KindStaff {
		t.Fatalf("the swap displaced %q, want the %q that was worn", done.Displaced, KindStaff)
	}
	if kind, wearing := wornKindIn(s, 1, SlotRightHand); !wearing || kind != KindSword {
		t.Fatalf("right hand holds %q in %+v, want the sword", kind, s.Worn(1))
	}
	if _, wearing := wornKindIn(s, 1, SlotLeftHand); wearing {
		t.Fatalf("left hand still holds %+v, want it free after the staff left", s.Worn(1))
	}
	staffs := 0
	for _, held := range s.Inventory(1) {
		if held.Kind == KindStaff {
			staffs++
		}
	}
	if staffs != 1 {
		t.Fatalf("the bag holds %d staffs after the swap, want exactly the one displaced", staffs)
	}
}

// TestEquippingATwoHandedToolOntoARightHandedWeaponSwapsThroughTheBagSlotItVacated
// is the 2H swap from an occupied right hand with a left hand still free: both
// hands come to hold the new kind and the old weapon lands in the bag slot the
// new kind left. M7b, AC3.
func TestEquippingATwoHandedToolOntoARightHandedWeaponSwapsThroughTheBagSlotItVacated(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}
	if _, err := s.SpawnInventoryItem(1, KindBow); err != nil {
		t.Fatalf("seeding a bow: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping the sword: %v", err)
	}

	done, err := s.EquipInventorySlot(1, 1)
	if err != nil {
		t.Fatalf("equipping the bow over the sword: %v", err)
	}

	if done.Displaced != KindSword {
		t.Fatalf("the swap displaced %q, want the %q that was worn", done.Displaced, KindSword)
	}
	if done.Bag != 1 {
		t.Fatalf("the swap reports bag slot %d, want 1, the one the bow left", done.Bag)
	}
	got := wornKindsIn(s, 1, KindBow)
	if len(got) != 2 {
		t.Fatalf("the bow is in %v, want both hands", got)
	}
	if held := s.Inventory(1); len(held) != 1 || held[0].Kind != KindSword || held[0].Index != 1 {
		t.Fatalf("the bag holds %+v, want the one displaced sword in slot 1", held)
	}
}

// TestEquippingATwoHandedToolOntoATwoHandedToolSwapsBothIntoOneBagSlot is the
// two-handed 2H↔2H swap: the left hand's weapon is lost to the swap and the
// right hand's weapon lands in the bag slot. The survivor is the right-hand
// item, which is what PROTOCOL.md's "Handedness" describes.
func TestEquippingATwoHandedToolOntoATwoHandedToolSwapsBothIntoOneBagSlot(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindStaff); err != nil {
		t.Fatalf("seeding a staff: %v", err)
	}
	if _, err := s.SpawnInventoryItem(1, KindBow); err != nil {
		t.Fatalf("seeding a bow: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping the staff: %v", err)
	}

	done, err := s.EquipInventorySlot(1, 1)
	if err != nil {
		t.Fatalf("equipping the bow over the staff: %v", err)
	}

	if done.Displaced != KindStaff {
		t.Fatalf("the swap displaced %q, want the %q that was in the right hand", done.Displaced, KindStaff)
	}
	got := wornKindsIn(s, 1, KindBow)
	if len(got) != 2 {
		t.Fatalf("the bow is in %v, want both hands", got)
	}
	if held := s.Inventory(1); len(held) != 1 || held[0].Kind != KindStaff {
		t.Fatalf("the bag holds %+v, want the one displaced staff", held)
	}
}

// TestACannotEquipATwoHandedToolWhenOnlyOneHandCouldBeFree is the atomicity
// half-apply test: the free hand cannot be filled first and then leave the
// other hand, because the move is one and the bag slot is the exchange. M7b,
// AC6 (sabotage).
func TestACannotEquipATwoHandedToolWhenOnlyOneHandCouldBeFree(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindSword); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}
	if _, err := s.SpawnInventoryItem(1, KindStaff); err != nil {
		t.Fatalf("seeding a staff: %v", err)
	}
	if _, err := s.EquipInventorySlot(1, 0); err != nil {
		t.Fatalf("equipping the sword: %v", err)
	}
	done, err := s.EquipInventorySlot(1, 1)
	if err != nil {
		t.Fatalf("equipping the staff: %v", err)
	}
	if done.Displaced != KindSword {
		t.Fatalf("the swap displaced %q, want %q", done.Displaced, KindSword)
	}
	got := wornKindsIn(s, 1, KindStaff)
	if len(got) != 2 || done.Worn != SlotLeftHand {
		t.Fatalf("the staff is in %v with reported slot %q, want both hands", got, done.Worn)
	}
}

// TestEquippingProspectorBootsUsesTheFeetSlot is the slot the brief adds for
// the prospector class. M7b.
func TestEquippingProspectorBootsUsesTheFeetSlot(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	if _, err := s.SpawnInventoryItem(1, KindProspectorBoots); err != nil {
		t.Fatalf("seeding prospector boots: %v", err)
	}

	done, err := s.EquipInventorySlot(1, 0)
	if err != nil {
		t.Fatalf("equipping prospector boots: %v", err)
	}

	want := Equipped{Worn: SlotFeet, Kind: KindProspectorBoots, Bag: 0}
	if done != want {
		t.Fatalf("the equip reported %+v, want %+v", done, want)
	}
	if kind, wearing := wornKindIn(s, 1, SlotFeet); !wearing || kind != KindProspectorBoots {
		t.Fatalf("feet holds %q in %+v, want the boots", kind, s.Worn(1))
	}
}

func equipKinds(t *testing.T, s Store, player mnet.PlayerID, kinds []string) {
	t.Helper()
	for _, kind := range kinds {
		slot, err := s.SpawnInventoryItem(player, kind)
		if err != nil {
			t.Fatalf("seed %q: %v", kind, err)
		}
		if _, err := s.EquipInventorySlot(player, slot.Index); err != nil {
			t.Fatalf("equip %q: %v", kind, err)
		}
	}
}

// TestEquipFullMinerViaStore proves miner class gear is sets-wearable and
// reaches the worn map only through EquipInventorySlot.
func TestEquipFullMinerViaStore(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	equipKinds(t, s, 1, []string{
		"prospector_helm",
		"prospector_jacket",
		"prospector_legs",
		KindProspectorBoots,
		KindPickaxe,
	})
	want := map[mnet.EquipSlot]string{
		SlotHelmet:    "prospector_helm",
		SlotChest:     "prospector_jacket",
		SlotTrousers:  "prospector_legs",
		SlotFeet:      KindProspectorBoots,
		SlotRightHand: KindPickaxe,
	}
	for slot, kind := range want {
		got, ok := wornKindIn(s, 1, slot)
		if !ok || got != kind {
			t.Fatalf("worn %q=%q, want %q (full worn %+v)", slot, got, kind, s.Worn(1))
		}
	}
}

// TestEquipFullLumberjackViaStore proves lumberjack class gear is sets-wearable
// and reaches the worn map only through EquipInventorySlot.
func TestEquipFullLumberjackViaStore(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)
	equipKinds(t, s, 1, []string{
		"forester_cap",
		"forester_shirt",
		"forester_trousers",
		KindLumberjackAxe,
	})
	want := map[mnet.EquipSlot]string{
		SlotHelmet:    "forester_cap",
		SlotChest:     "forester_shirt",
		SlotTrousers:  "forester_trousers",
		SlotLeftHand:  KindLumberjackAxe,
		SlotRightHand: KindLumberjackAxe,
	}
	for slot, kind := range want {
		got, ok := wornKindIn(s, 1, slot)
		if !ok || got != kind {
			t.Fatalf("worn %q=%q, want %q (full worn %+v)", slot, got, kind, s.Worn(1))
		}
	}
}
