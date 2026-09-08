package game


import (
	"errors"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

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

func wornKindIn(s Store, player mnet.PlayerID, slot mnet.EquipSlot) (string, bool) {
	for _, w := range s.Worn(player) {
		if w.Slot == slot {
			return w.Kind, true
		}
	}
	return "", false
}

func TestWornSlotsAndTheKindTableAgree(t *testing.T) {
	equipped := make(map[mnet.EquipSlot]bool, len(WornSlots))
	for kind, slots := range testWearables(t) {
		for _, slot := range slots {
			if !wornSlotExists(slot) {
				t.Errorf("kind %q equips into %q, which is not in WornSlots %v: it could be worn and never removed", kind, slot, WornSlots)
			}
			equipped[slot] = true
		}
	}
	seen := make(map[mnet.EquipSlot]bool, len(WornSlots))
	for _, slot := range WornSlots {
		if seen[slot] {
			t.Errorf("WornSlots lists %q twice: %v", slot, WornSlots)
		}
		seen[slot] = true
		if !equipped[slot] {
			t.Errorf("WornSlots lists %q, which no kind in shared/sets.json equips into: the client derives its worn vocabulary from sets.json, so it can never see %q and would reject every equipment frame naming it", slot, slot)
		}
	}
}

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
		t.Fatalf("the bag holds %+v, want the one sword back in slot 0", held)
	}
}

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

func TestUnequippingAnEmptyWornSlotIsItsOwnRefusal(t *testing.T) {
	s := newStore(t)
	s.AddPlayer(1)

	if _, err := s.UnequipWornSlot(1, SlotRightHand); !errors.Is(err, ErrEmptyWornSlot) {
		t.Fatalf("unequipping an empty worn slot returned %v, want ErrEmptyWornSlot", err)
	}
}

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

func wornKindsIn(s Store, player mnet.PlayerID, kind string) []mnet.EquipSlot {
	var slots []mnet.EquipSlot
	for _, w := range s.Worn(player) {
		if w.Kind == kind {
			slots = append(slots, w.Slot)
		}
	}
	return slots
}

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
