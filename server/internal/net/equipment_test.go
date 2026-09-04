package net_test

// M3a's acceptance: worn slots, equip and unequip, and the equipment
// restatement, driven through real sockets against a world configured the way
// the shipped server configures itself.
//
// Every test here uses newHarnessWithKit with game.DefaultJoinKit, so the axe
// under test is the one a real player joins holding rather than one the test
// arranged for itself.

import (
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// fullBagKit is a join kit that fills the bag: the axe M3a equips, and acorns
// in every remaining slot.
func fullBagKit() []string {
	kit := make([]string, 0, game.InventorySize)
	kit = append(kit, game.KindAxe)
	for len(kit) < game.InventorySize {
		kit = append(kit, game.KindAcorn)
	}
	return kit
}

// wornKind reports what one equipment restatement says is in a worn slot.
func wornKind(equipment mnet.Equipment, slot mnet.EquipSlot) (string, bool) {
	for _, s := range equipment.Slots {
		if s.Slot == slot {
			return s.Kind, true
		}
	}
	return "", false
}

// bagKind reports what one inventory restatement says is in a bag slot.
func bagKind(inv mnet.Inventory, slot int) (string, bool) {
	for _, s := range inv.Slots {
		if s.Slot == slot {
			return s.Kind, true
		}
	}
	return "", false
}

// countKinds tallies one client's frames by message name, which is how a test
// says "exactly one of each restatement" rather than "at least one".
func countKinds(frames []frame) map[string]int {
	kinds := make(map[string]int)
	for _, f := range frames {
		kinds[f.kind()]++
	}
	return kinds
}

// TestDefaultJoinKitIsOneAxe pins the tunable the rest of this file is written
// against. Every test below configures its world with DefaultJoinKit, so a kit
// that quietly grew a second item would move every bag index they assert.
func TestDefaultJoinKitIsOneAxe(t *testing.T) {
	if len(game.DefaultJoinKit) != 1 || game.DefaultJoinKit[0] != game.KindAxe {
		t.Fatalf("DefaultJoinKit is %v, want exactly one %q", game.DefaultJoinKit, game.KindAxe)
	}
	if len(game.WornSlots) != 1 || game.WornSlots[0] != game.SlotWeapon {
		t.Fatalf("WornSlots is %v, want exactly %q", game.WornSlots, game.SlotWeapon)
	}
}

// TestTheJoinKitPutsOneAxeInTheLowestFreeBagSlot is the precondition for
// equipping anything: a client can reach equip without gathering content.
//
// It also holds the kit to being a bag item and not a world item. An axe placed
// on the ground and picked up would satisfy "the player has an axe" and would
// mint an item id, broadcast an item_spawn to everybody, and leave a second
// client drawing an axe nobody can see.
func TestTheJoinKitPutsOneAxeInTheLowestFreeBagSlot(t *testing.T) {
	h := newHarnessWithKit(t, game.DefaultJoinKit)

	alice := h.dial("alice")
	world := alice.welcomeFrame()
	held := alice.inventory()

	if len(world.Items) != 0 {
		t.Fatalf("the world holds %+v, want nothing: the join kit is a bag item, not a ground item", world.Items)
	}
	if len(held.Slots) != 1 {
		t.Fatalf("a joining player holds %+v, want exactly the one axe of the kit", held.Slots)
	}
	if got := held.Slots[0]; got.Slot != 0 || got.Kind != game.KindAxe {
		t.Fatalf("the kit landed as %q in slot %d, want an axe in slot 0, the lowest free one", got.Kind, got.Slot)
	}

	seeded := h.awaitEvents(game.EvJoinSeeded, 1)
	if got := seeded[0]["kind"]; got != game.KindAxe {
		t.Errorf("%s names kind %v, want %q", game.EvJoinSeeded, got, game.KindAxe)
	}
	if got := seeded[0]["slot"]; got != float64(0) {
		t.Errorf("%s names slot %v, want 0", game.EvJoinSeeded, got)
	}
	if spawned := h.eventsNamed(game.EvItemSpawned); len(spawned) != 0 {
		t.Errorf("the join kit logged %s: %+v; nothing entered the world", game.EvItemSpawned, spawned)
	}
}

// TestAFreshPlayerIsToldItsWornSlotsAndThatTheyAreEmpty is the equipment frame's
// own half of the join step, and the frame where PROTOCOL.md's "an empty list is
// [], never null" rule is exercised on every single join.
//
// A strict client reading "slots":null as "not an array" drops the whole frame
// and never draws its panel, with nothing wrong-looking on either side.
func TestAFreshPlayerIsToldItsWornSlotsAndThatTheyAreEmpty(t *testing.T) {
	h := newHarnessWithKit(t, game.DefaultJoinKit)

	alice := h.dial("alice")
	alice.welcomeFrame()
	alice.inventory()
	f := alice.equipmentFrame()
	worn := *f.Equipment

	if len(worn.Slots) != 0 {
		t.Fatalf("a joining player is wearing %+v, want nothing", worn.Slots)
	}
	if len(worn.Worn) != len(game.WornSlots) || worn.Worn[0] != game.SlotWeapon {
		t.Fatalf("equipment names slots %v, want the server's own list %v", worn.Worn, game.WornSlots)
	}
	if !strings.Contains(f.raw, `"slots":[]`) {
		t.Errorf("an empty equipment encodes as %s, want it to carry \"slots\":[]", f.raw)
	}
	if !strings.Contains(f.raw, `"worn":["weapon"]`) {
		t.Errorf("equipment encodes as %s, want \"worn\" to be an array of names", f.raw)
	}
	assertNoNulls(t, "equipment", f.raw)

	// The step ends here. An equipment frame that arrived before the inventory,
	// or a second one, would be a join step nobody specified.
	alice.expectSilence()
}

// TestEquippingAnAxeIsOneMoveFromBagToWeapon is AC1.
//
// The hazards it exists for are the three ways one transaction can be written as
// two: the axe in both containers, in neither, or on the ground. A get-then-put
// implementation passes "the axe is worn" and fails at least one of the others.
func TestEquippingAnAxeIsOneMoveFromBagToWeapon(t *testing.T) {
	h := newHarnessWithKit(t, game.DefaultJoinKit)

	alice := h.dial("alice")
	alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()
	alice.drain()
	bob.drain()

	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)

	frames := alice.collect(silenceWindow)
	kinds := countKinds(frames)
	if kinds["inventory"] != 1 || kinds["equipment"] != 1 {
		t.Fatalf("one equip sent %v, want exactly one inventory and one equipment: both containers changed, so both are restated once", kinds)
	}
	if kinds["item_spawn"] != 0 {
		t.Fatalf("one equip sent %d item_spawn frames; an equip never puts anything on the ground", kinds["item_spawn"])
	}
	if len(frames) != 2 {
		t.Fatalf("one equip sent %d frames (%v), want only the two restatements", len(frames), kinds)
	}

	var held mnet.Inventory
	var worn mnet.Equipment
	for _, f := range frames {
		switch {
		case f.Inventory != nil:
			held = *f.Inventory
		case f.Equipment != nil:
			worn = *f.Equipment
		}
	}

	kind, wearing := wornKind(worn, game.SlotWeapon)
	if !wearing || kind != game.KindAxe {
		t.Fatalf("alice is wearing %+v, want an axe in %q", worn.Slots, game.SlotWeapon)
	}
	if _, occupied := bagKind(held, 0); occupied {
		t.Fatalf("bag slot 0 still holds something after the axe left it: %+v; the axe is in both places at once", held.Slots)
	}
	if len(held.Slots) != 0 {
		t.Fatalf("alice's bag holds %+v, want it emptied by the equip", held.Slots)
	}

	// The other half of "in exactly one place". A world snapshot composed by the
	// server itself is the authoritative answer to "is the axe on the ground",
	// and it is not a list the test assembled.
	charlie := h.dial("charlie")
	if world := charlie.welcomeFrame(); len(world.Items) != 0 {
		t.Fatalf("the world holds %+v after an equip, want nothing on the ground", world.Items)
	}

	// An equip is unicast. Bob is in the same world and learns nothing at all
	// about what alice is wearing.
	for _, f := range bob.collect(silenceWindow) {
		if f.Spawn == nil {
			t.Errorf("bob was sent a %s frame for alice's equip: %s", f.kind(), f.raw)
		}
	}

	equipped := h.eventsNamed(game.EvEquip)
	if len(equipped) != 1 {
		t.Fatalf("logged %d %s events, want 1: %+v", len(equipped), game.EvEquip, equipped)
	}
	ev := equipped[0]
	if ev["kind"] != game.KindAxe || ev["worn"] != string(game.SlotWeapon) || ev["slot"] != float64(0) {
		t.Errorf("%s reads %+v, want the axe going from slot 0 to %q", game.EvEquip, ev, game.SlotWeapon)
	}
	if _, swapped := ev["displaced"]; swapped {
		t.Errorf("%s carries \"displaced\" for an equip into a free slot: %+v", game.EvEquip, ev)
	}
}

// TestUnequippingReturnsTheAxeToTheLowestFreeBagSlot is AC2, and it is AC1's
// transaction read backwards: the same three hazards in the other direction.
func TestUnequippingReturnsTheAxeToTheLowestFreeBagSlot(t *testing.T) {
	h := newHarnessWithKit(t, game.DefaultJoinKit)

	alice := h.dial("alice")
	alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.unequip(game.SlotWeapon)
	h.awaitEvents(game.EvUnequip, 1)

	frames := alice.collect(silenceWindow)
	kinds := countKinds(frames)
	if kinds["inventory"] != 1 || kinds["equipment"] != 1 || len(frames) != 2 {
		t.Fatalf("one unequip sent %v, want exactly one inventory and one equipment and nothing else", kinds)
	}

	var held mnet.Inventory
	var worn mnet.Equipment
	for _, f := range frames {
		switch {
		case f.Inventory != nil:
			held = *f.Inventory
		case f.Equipment != nil:
			worn = *f.Equipment
		}
	}

	if len(worn.Slots) != 0 {
		t.Fatalf("alice is still wearing %+v after taking it off", worn.Slots)
	}
	if len(held.Slots) != 1 {
		t.Fatalf("alice's bag holds %+v, want exactly the one axe back: more than one is a dupe", held.Slots)
	}
	if got := held.Slots[0]; got.Slot != 0 || got.Kind != game.KindAxe {
		t.Fatalf("the axe came back as %q in slot %d, want an axe in slot 0, the lowest free one", got.Kind, got.Slot)
	}

	if world := h.dial("charlie").welcomeFrame(); len(world.Items) != 0 {
		t.Fatalf("the world holds %+v after an unequip, want nothing on the ground", world.Items)
	}

	unequipped := h.eventsNamed(game.EvUnequip)
	if len(unequipped) != 1 {
		t.Fatalf("logged %d %s events, want 1: %+v", len(unequipped), game.EvUnequip, unequipped)
	}
	if ev := unequipped[0]; ev["kind"] != game.KindAxe || ev["worn"] != string(game.SlotWeapon) || ev["slot"] != float64(0) {
		t.Errorf("%s reads %+v, want the axe coming from %q into slot 0", game.EvUnequip, ev, game.SlotWeapon)
	}
}

// TestUnequipFillsTheLowestFreeSlotRatherThanTheOneItLeft. "Lowest free" is
// RuneScape's rule and the one every path into the bag uses, so an unequip must
// not remember where the item came from.
func TestUnequipFillsTheLowestFreeSlotRatherThanTheOneItLeft(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindAcorn, game.KindAxe})

	alice := h.dial("alice")
	alice.welcome()

	// The axe is in slot 1, behind an acorn. Equipping it and dropping the acorn
	// leaves slot 0 as the lowest free slot and slot 1 as the one it left.
	alice.equip(1)
	h.awaitEvents(game.EvEquip, 1)
	alice.drop(0)
	h.awaitEvents(game.EvDrop, 1)
	alice.drain()

	alice.unequip(game.SlotWeapon)
	h.awaitEvents(game.EvUnequip, 1)

	held := alice.awaitInventory()
	if len(held.Slots) != 1 {
		t.Fatalf("alice holds %+v, want just the axe", held.Slots)
	}
	if got := held.Slots[0]; got.Slot != 0 {
		t.Fatalf("the axe came back to slot %d, want slot 0: an unequip fills the lowest free slot, not the one it vacated", got.Slot)
	}
}

// TestEquippingAnAcornIsRefusedAndBothContainersAreUnchanged is AC3.
//
// The refusal is a table lookup that misses rather than a rule naming the kinds
// that are not weapons, so this is the ordinary case for every kind M3a ships
// bar one.
func TestEquippingAnAcornIsRefusedAndBothContainersAreUnchanged(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindAcorn})

	alice := h.dial("alice")
	alice.welcome()
	alice.drain()

	alice.equip(0)

	if got := alice.awaitError(); got.Re != mnet.MsgEquip {
		t.Fatalf("the refusal names %q, want %q: %+v", got.Re, mnet.MsgEquip, got)
	}
	rejected := h.awaitEvents(game.EvEquipRejected, 1)
	if got := rejected[0]["reason"]; got != string(mnet.ReasonNotEquippable) {
		t.Errorf("%s reads reason %v, want %q", game.EvEquipRejected, got, mnet.ReasonNotEquippable)
	}

	// A refusal restates nothing, because nothing changed. Anything here is the
	// server telling a client about a transaction it declined to make.
	alice.expectSilence()

	// And the state is what it was, read from a fresh join step rather than from
	// a restatement the refusal was just asserted not to have sent.
	again := h.dial("alice-observer")
	again.welcomeFrame()
	again.inventory()
	if worn := again.equipment(); len(worn.Slots) != 0 {
		t.Fatalf("a second player is wearing %+v; worn slots are per player", worn.Slots)
	}

	alice.close()
	held := h.dial("alice-check")
	held.welcomeFrame()
	if bag := held.inventory(); len(bag.Slots) != 1 || bag.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("the refused equip left the joining bag as %+v, want the one acorn the kit gives", bag.Slots)
	}
}

// TestEquipRefusalsNameTheirReasonAndChangeNothing covers the two refusals that
// are about the bag index rather than the kind, which is the same pair drop is
// held to and for the same reasons: one is a broken client, the other a stale
// one.
func TestEquipRefusalsNameTheirReasonAndChangeNothing(t *testing.T) {
	cases := []struct {
		name string
		slot int
		want mnet.RejectReason
	}{
		{"below the first slot", -1, mnet.ReasonNoSuchSlot},
		{"one past the last slot", game.InventorySize, mnet.ReasonNoSuchSlot},
		{"far outside the bag", 1 << 20, mnet.ReasonNoSuchSlot},
		{"a legal slot holding nothing", 1, mnet.ReasonEmptySlot},
		{"the last slot, empty", game.InventorySize - 1, mnet.ReasonEmptySlot},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarnessWithKit(t, game.DefaultJoinKit)
			alice := h.dial("alice")
			alice.welcome()
			alice.drain()

			alice.equip(tc.slot)

			if got := alice.awaitError(); got.Re != mnet.MsgEquip {
				t.Fatalf("the refusal names %q, want %q: %+v", got.Re, mnet.MsgEquip, got)
			}
			rejected := h.awaitEvents(game.EvEquipRejected, 1)
			if got := rejected[0]["reason"]; got != string(tc.want) {
				t.Errorf("%s reads reason %v, want %q", game.EvEquipRejected, got, tc.want)
			}
			alice.expectSilence()
		})
	}
}

// TestUnequippingIntoAFullBagIsRefusedAndTheAxeStaysWorn is AC4.
//
// The failure this forbids is not a crash. It is the server helpfully dropping
// the axe at the player's feet, where this protocol gives ground items no owner
// and no visibility rules, so anybody standing there takes it. Losing the item
// outright is the other way to pass "the worn slot is empty".
func TestUnequippingIntoAFullBagIsRefusedAndTheAxeStaysWorn(t *testing.T) {
	// One acorn underfoot, so refilling the slot the equip vacates costs one
	// tick and no walk.
	h := newHarnessWithKit(t, fullBagKit(), acornAt(0, 0))

	alice := h.dial("alice")
	world := alice.welcome()
	underfoot := world.Items[0].ID

	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	// The equip's own restatement first, so the inventory read below is the one
	// the pickup caused rather than the one that freed the slot it fills.
	alice.drain()

	alice.pickup(underfoot)
	h.awaitEvents(game.EvPickupResolved, 1)

	full := alice.awaitInventory()
	if len(full.Slots) != game.InventorySize {
		t.Fatalf("the bag holds %d of %d slots, want it full before the unequip is attempted", len(full.Slots), game.InventorySize)
	}
	alice.drain()

	alice.unequip(game.SlotWeapon)

	got := alice.awaitError()
	if got.Re != mnet.MsgUnequip {
		t.Fatalf("the refusal names %q, want %q: %+v", got.Re, mnet.MsgUnequip, got)
	}
	if !strings.Contains(got.Msg, "full") {
		t.Errorf("the refusal reads %q, want it to say the inventory is full", got.Msg)
	}
	rejected := h.awaitEvents(game.EvUnequipRejected, 1)
	if r := rejected[0]["reason"]; r != string(mnet.ReasonInventoryFull) {
		t.Errorf("%s reads reason %v, want %q", game.EvUnequipRejected, r, mnet.ReasonInventoryFull)
	}

	// Nothing was dropped: no item_spawn to anybody, and the ground still holds
	// only what the world started with, which the pickup already took.
	for _, f := range alice.collect(silenceWindow) {
		t.Errorf("a refused unequip sent alice a %s frame: %s", f.kind(), f.raw)
	}
	if snapshot := h.dial("charlie").welcomeFrame(); len(snapshot.Items) != 0 {
		t.Fatalf("the world holds %+v after a refused unequip; the axe was dropped rather than kept", snapshot.Items)
	}
	if spawns := h.eventsNamed(game.EvItemSpawned); len(spawns) != 1 {
		t.Fatalf("logged %d %s events, want only the one seeded acorn: %+v", len(spawns), game.EvItemSpawned, spawns)
	}

	// And the axe is still worn, not lost. Read from a resumed join step, which
	// is the server restating what it holds rather than the test remembering.
	alice.destroy()
	resumed := readJoinStep(h.dialResume("alice-again", world.Session))
	kind, wearing := wornKind(resumed.equipment, game.SlotWeapon)
	if !wearing || kind != game.KindAxe {
		t.Fatalf("alice is wearing %+v after the refusal, want the axe still on", resumed.equipment.Slots)
	}
	if len(resumed.inventory.Slots) != game.InventorySize {
		t.Fatalf("alice's bag holds %d slots after the refusal, want the same full %d", len(resumed.inventory.Slots), game.InventorySize)
	}
}

// TestUnequipRefusalsNameTheirReasonAndChangeNothing covers the two refusals
// about the worn slot name: one this server does not have, and one it has that
// holds nothing. Membership is the game's question, not the decoder's, which is
// why an empty name lands here rather than as malformed JSON.
func TestUnequipRefusalsNameTheirReasonAndChangeNothing(t *testing.T) {
	cases := []struct {
		name string
		worn mnet.EquipSlot
		want mnet.RejectReason
	}{
		{"a slot this server does not have", "helmet", mnet.ReasonNoSuchWornSlot},
		{"a name that is no name at all", "", mnet.ReasonNoSuchWornSlot},
		{"the wrong case", "WEAPON", mnet.ReasonNoSuchWornSlot},
		{"a slot it has, wearing nothing", game.SlotWeapon, mnet.ReasonEmptyWornSlot},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarnessWithKit(t, game.DefaultJoinKit)
			alice := h.dial("alice")
			alice.welcome()
			alice.drain()

			alice.unequip(tc.worn)

			if got := alice.awaitError(); got.Re != mnet.MsgUnequip {
				t.Fatalf("the refusal names %q, want %q: %+v", got.Re, mnet.MsgUnequip, got)
			}
			rejected := h.awaitEvents(game.EvUnequipRejected, 1)
			if got := rejected[0]["reason"]; got != string(tc.want) {
				t.Errorf("%s reads reason %v, want %q", game.EvUnequipRejected, got, tc.want)
			}
			alice.expectSilence()
		})
	}
}

// TestUnequipNamingABagIndexIsRefusedAsAMissingField is the confusion the field
// name exists to prevent, held to producing a refusal rather than an accident.
// A client that sends drop's field to unequip has named no worn slot at all.
func TestUnequipNamingABagIndexIsRefusedAsAMissingField(t *testing.T) {
	h := newHarnessWithKit(t, game.DefaultJoinKit)
	alice := h.dial("alice")
	alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.sendRaw(`{"unequip":{"slot":0}}`)

	if got := alice.awaitError(); got.Re != mnet.MsgUnequip {
		t.Fatalf("the refusal names %q, want %q: %+v", got.Re, mnet.MsgUnequip, got)
	}
	rejected := h.awaitEvents(game.EvUnequipRejected, 1)
	if got := rejected[0]["reason"]; got != string(mnet.ReasonMissingField) {
		t.Errorf("%s reads reason %v, want %q", game.EvUnequipRejected, got, mnet.ReasonMissingField)
	}
	alice.expectSilence()
}

// TestEquippingOntoAWornAxeSwapsThroughTheVacatedSlot. RuneScape swaps, and the
// swap is also what makes equip total: it needs no free slot, because the slot
// the new item is leaving is the one the old item lands in.
func TestEquippingOntoAWornAxeSwapsThroughTheVacatedSlot(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindAxe, game.KindAxe})

	alice := h.dial("alice")
	alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.equip(1)
	h.awaitEvents(game.EvEquip, 2)

	frames := alice.collect(silenceWindow)
	if kinds := countKinds(frames); kinds["inventory"] != 1 || kinds["equipment"] != 1 || len(frames) != 2 {
		t.Fatalf("a swap sent %v, want one inventory and one equipment", kinds)
	}

	var held mnet.Inventory
	var worn mnet.Equipment
	for _, f := range frames {
		switch {
		case f.Inventory != nil:
			held = *f.Inventory
		case f.Equipment != nil:
			worn = *f.Equipment
		}
	}

	if len(worn.Slots) != 1 || worn.Slots[0].Kind != game.KindAxe {
		t.Fatalf("alice is wearing %+v, want the one axe the swap put on", worn.Slots)
	}
	if len(held.Slots) != 1 {
		t.Fatalf("alice's bag holds %+v, want exactly the displaced axe: two axes went in, two must come out", held.Slots)
	}
	if got := held.Slots[0]; got.Slot != 1 || got.Kind != game.KindAxe {
		t.Fatalf("the displaced axe is %q in slot %d, want an axe in slot 1, the one the new axe left", got.Kind, got.Slot)
	}

	swapped := h.eventsNamed(game.EvEquip)
	if got := swapped[1]["displaced"]; got != game.KindAxe {
		t.Errorf("%s reads displaced %v, want %q: the field is the whole record that a swap happened", game.EvEquip, got, game.KindAxe)
	}
}

// TestWornEquipmentSurvivesSuspendAndResume is AC5.
//
// Worn equipment belongs to the player and the player outlives its socket, so
// this asserts a consequence of where the state lives rather than a mechanism
// of its own. It is the regression test for somebody later moving worn slots
// onto the connection, where it would look correct until a cable came out.
func TestWornEquipmentSurvivesSuspendAndResume(t *testing.T) {
	h := newHarnessWithKit(t, game.DefaultJoinKit)

	alice := h.dial("alice")
	first := alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)

	before := alice.awaitEquipmentBeforeDeath(t)

	// An abrupt death, which is what suspends rather than retires: no close
	// frame, so the server reads peer_gone.
	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)

	resumed := readJoinStep(h.dialResume("alice-again", first.Session))
	if resumed.welcome.You != first.You {
		t.Fatalf("the resume was handed player %d, want %d back", resumed.welcome.You, first.You)
	}

	kind, wearing := wornKind(resumed.equipment, game.SlotWeapon)
	if !wearing {
		t.Fatalf("the resumed player is wearing %+v, want the axe it had on when the socket died", resumed.equipment.Slots)
	}
	if kind != before {
		t.Fatalf("the resumed player is wearing %q, want the %q it had on before", kind, before)
	}
	if len(resumed.equipment.Slots) != 1 {
		t.Fatalf("the resumed player is wearing %+v, want exactly one thing: a resume that duplicates is as wrong as one that loses", resumed.equipment.Slots)
	}
	if len(resumed.inventory.Slots) != 0 {
		t.Fatalf("the resumed bag holds %+v, want it empty: the axe is worn, and a copy in the bag is a dupe", resumed.inventory.Slots)
	}
	if len(resumed.equipment.Worn) != len(game.WornSlots) {
		t.Errorf("the resumed equipment names slots %v, want the server's list %v", resumed.equipment.Worn, game.WornSlots)
	}
}

// awaitEquipmentBeforeDeath reads the kind in the weapon slot from the
// restatement the equip sent, so the resume assertion compares against what the
// server said rather than against what the test arranged.
func (c *client) awaitEquipmentBeforeDeath(t *testing.T) string {
	t.Helper()

	deadline := silenceWindow
	for _, f := range c.collect(deadline) {
		if f.Equipment == nil {
			continue
		}
		if kind, wearing := wornKind(*f.Equipment, game.SlotWeapon); wearing {
			return kind
		}
	}
	t.Fatalf("client %s: no equipment naming a worn %q arrived", c.name, game.SlotWeapon)
	return ""
}

// TestWornEquipmentDiesWithThePlayer is AC5's boundary. A clean logout retires
// the player, and worn equipment goes with everything else it was holding.
func TestWornEquipmentDiesWithThePlayer(t *testing.T) {
	h := newHarnessWithKit(t, game.DefaultJoinKit)

	alice := h.dial("alice")
	first := alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.close()
	h.awaitEvents(game.EvDisconnected, 1)

	// The token is dead, so this is a fresh join with a fresh kit rather than a
	// resume, and the client can tell because you and session both differ.
	fresh := readJoinStep(h.dialResume("alice-again", first.Session))
	if fresh.welcome.You == first.You {
		t.Fatalf("a logged-out player's token was handed back player %d", fresh.welcome.You)
	}
	if len(fresh.equipment.Slots) != 0 {
		t.Fatalf("a fresh player is wearing %+v, want nothing: worn equipment dies with the player", fresh.equipment.Slots)
	}
	if len(fresh.inventory.Slots) != 1 || fresh.inventory.Slots[0].Kind != game.KindAxe {
		t.Fatalf("a fresh player holds %+v, want the one axe of its own kit", fresh.inventory.Slots)
	}
}

// TestASequencedEquipIsDedupedAndLogsItsSeq holds M3a's two intents to the rule
// PROTOCOL.md's "Sequence numbers" states once at the envelope for all of them.
// A retried equip must not equip twice.
func TestASequencedEquipIsDedupedAndLogsItsSeq(t *testing.T) {
	h := newHarnessWithKit(t, game.DefaultJoinKit)

	alice := h.dial("alice")
	alice.welcome()
	alice.drain()

	alice.sendRaw(`{"equip":{"slot":0,"seq":4}}`)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	// The same number again, which is the retry a client sends when it did not
	// see the restatement.
	alice.sendRaw(`{"equip":{"slot":0,"seq":4}}`)
	h.awaitEvents(game.EvIntentDuplicate, 1)

	if got := h.eventsNamed(game.EvEquip); len(got) != 1 {
		t.Fatalf("logged %d %s events for one number sent twice, want 1: %+v", len(got), game.EvEquip, got)
	}
	if got := h.eventsNamed(game.EvEquip)[0]["seq"]; got != float64(4) {
		t.Errorf("%s reads seq %v, want 4", game.EvEquip, got)
	}
	// A duplicate is not answered at all, so there is no second restatement and
	// no error.
	alice.expectSilence()
}
