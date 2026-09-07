package net_test


import (
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func fullBagKit() []string {
	kit := make([]string, 0, game.InventorySize)
	kit = append(kit, game.KindSword)
	for len(kit) < game.InventorySize {
		kit = append(kit, game.KindAcorn)
	}
	return kit
}

func wornKind(equipment mnet.Equipment, slot mnet.EquipSlot) (string, bool) {
	for _, s := range equipment.Slots {
		if s.Slot == slot {
			return s.Kind, true
		}
	}
	return "", false
}

func bagKind(inv mnet.Inventory, slot int) (string, bool) {
	for _, s := range inv.Slots {
		if s.Slot == slot {
			return s.Kind, true
		}
	}
	return "", false
}

func countKinds(frames []frame) map[string]int {
	kinds := make(map[string]int)
	for _, f := range frames {
		kinds[f.kind()]++
	}
	return kinds
}

func TestDefaultJoinKitIsEmpty(t *testing.T) {
	if len(game.DefaultJoinKit) != 0 {
		t.Fatalf("DefaultJoinKit is %v, want empty", game.DefaultJoinKit)
	}
	wantWorn := []mnet.EquipSlot{
		game.SlotHelmet, game.SlotLeftHand, game.SlotChest, game.SlotRightHand, game.SlotFeet, game.SlotTrousers,
	}
	if len(game.WornSlots) != len(wantWorn) {
		t.Fatalf("WornSlots is %v, want %v", game.WornSlots, wantWorn)
	}
	for i, slot := range wantWorn {
		if game.WornSlots[i] != slot {
			t.Fatalf("WornSlots is %v, want %v", game.WornSlots, wantWorn)
		}
	}
}

func TestTheJoinKitPutsOneSwordInTheLowestFreeBagSlot(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword})

	alice := h.dial("alice")
	world := alice.welcomeFrame()
	held := alice.inventory()

	if len(world.Items) != 0 {
		t.Fatalf("the world holds %+v, want nothing: the join kit is a bag item, not a ground item", world.Items)
	}
	if len(held.Slots) != 1 {
		t.Fatalf("a joining player holds %+v, want exactly the one sword of the kit", held.Slots)
	}
	if got := held.Slots[0]; got.Slot != 0 || got.Kind != game.KindSword {
		t.Fatalf("the kit landed as %q in slot %d, want a sword in slot 0, the lowest free one", got.Kind, got.Slot)
	}

	seeded := h.awaitEvents(game.EvJoinSeeded, 1)
	if got := seeded[0]["kind"]; got != game.KindSword {
		t.Errorf("%s names kind %v, want %q", game.EvJoinSeeded, got, game.KindSword)
	}
	if got := seeded[0]["slot"]; got != float64(0) {
		t.Errorf("%s names slot %v, want 0", game.EvJoinSeeded, got)
	}
	if spawned := h.eventsNamed(game.EvItemSpawned); len(spawned) != 0 {
		t.Errorf("the join kit logged %s: %+v; nothing entered the world", game.EvItemSpawned, spawned)
	}
}

func TestAFreshPlayerIsToldItsWornSlotsAndThatTheyAreEmpty(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword})

	alice := h.dial("alice")
	alice.welcomeFrame()
	alice.inventory()
	f := alice.equipmentFrame()
	worn := *f.Equipment

	if len(worn.Slots) != 0 {
		t.Fatalf("a joining player is wearing %+v, want nothing", worn.Slots)
	}
	if len(worn.Worn) != len(game.WornSlots) {
		t.Fatalf("equipment names slots %v, want the server's own list %v", worn.Worn, game.WornSlots)
	}
	for i, slot := range game.WornSlots {
		if worn.Worn[i] != slot {
			t.Fatalf("equipment names slots %v, want the server's own list %v", worn.Worn, game.WornSlots)
		}
	}
	if !strings.Contains(f.raw, `"slots":[]`) {
		t.Errorf("an empty equipment encodes as %s, want it to carry \"slots\":[]", f.raw)
	}
	if !strings.Contains(f.raw, `"worn":["helmet","left hand","chest","right hand","feet","trousers"]`) {
		t.Errorf("equipment encodes as %s, want \"worn\" to be an array of names", f.raw)
	}
	assertNoNulls(t, "equipment", f.raw)

	if got := alice.classFrame(); got.Class != "" {
		t.Fatalf("a fresh player's class frame reports %q, want none", got.Class)
	}
	skills := alice.skillsFrame()
	if len(skills.Skills) != 5 {
		t.Fatalf("a fresh player's skills frame lists %d skills, want 5", len(skills.Skills))
	}
	for _, sk := range skills.Skills {
		if sk.XP != 0 || sk.Level != 1 {
			t.Fatalf("fresh skill %q reports xp=%d level=%d, want 0 and 1", sk.ID, sk.XP, sk.Level)
		}
	}

	alice.expectSilence()
}

func TestEquippingASwordIsOneMoveFromBagToWeapon(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword})

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
	if kinds["inventory"] != 1 || kinds["equipment"] != 1 || kinds["class"] != 1 {
		t.Fatalf("one equip sent %v, want exactly one inventory, one equipment and one class: the containers changed and the class derives from them, so all three are restated once", kinds)
	}
	if kinds["item_spawn"] != 0 {
		t.Fatalf("one equip sent %d item_spawn frames; an equip never puts anything on the ground", kinds["item_spawn"])
	}
	if len(frames) != 3 {
		t.Fatalf("one equip sent %d frames (%v), want only the three restatements", len(frames), kinds)
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

	kind, wearing := wornKind(worn, game.SlotRightHand)
	if !wearing || kind != game.KindSword {
		t.Fatalf("alice is wearing %+v, want a sword in %q", worn.Slots, game.SlotRightHand)
	}
	if _, occupied := bagKind(held, 0); occupied {
		t.Fatalf("bag slot 0 still holds something after the sword left it: %+v; the sword is in both places at once", held.Slots)
	}
	if len(held.Slots) != 0 {
		t.Fatalf("alice's bag holds %+v, want it emptied by the equip", held.Slots)
	}

	charlie := h.dial("charlie")
	if world := charlie.welcomeFrame(); len(world.Items) != 0 {
		t.Fatalf("the world holds %+v after an equip, want nothing on the ground", world.Items)
	}

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
	if ev["kind"] != game.KindSword || ev["worn"] != string(game.SlotRightHand) || ev["slot"] != float64(0) {
		t.Errorf("%s reads %+v, want the sword going from slot 0 to %q", game.EvEquip, ev, game.SlotRightHand)
	}
	if _, swapped := ev["displaced"]; swapped {
		t.Errorf("%s carries \"displaced\" for an equip into a free slot: %+v", game.EvEquip, ev)
	}
}

func TestUnequippingReturnsTheSwordToTheLowestFreeBagSlot(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword})

	alice := h.dial("alice")
	alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.unequip(game.SlotRightHand)
	h.awaitEvents(game.EvUnequip, 1)

	frames := alice.collect(silenceWindow)
	kinds := countKinds(frames)
	if kinds["inventory"] != 1 || kinds["equipment"] != 1 || kinds["class"] != 1 || len(frames) != 3 {
		t.Fatalf("one unequip sent %v, want exactly one inventory, one equipment and one class and nothing else", kinds)
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
		t.Fatalf("alice's bag holds %+v, want exactly the one sword back: more than one is a dupe", held.Slots)
	}
	if got := held.Slots[0]; got.Slot != 0 || got.Kind != game.KindSword {
		t.Fatalf("the sword came back as %q in slot %d, want a sword in slot 0, the lowest free one", got.Kind, got.Slot)
	}

	if world := h.dial("charlie").welcomeFrame(); len(world.Items) != 0 {
		t.Fatalf("the world holds %+v after an unequip, want nothing on the ground", world.Items)
	}

	unequipped := h.eventsNamed(game.EvUnequip)
	if len(unequipped) != 1 {
		t.Fatalf("logged %d %s events, want 1: %+v", len(unequipped), game.EvUnequip, unequipped)
	}
	if ev := unequipped[0]; ev["kind"] != game.KindSword || ev["worn"] != string(game.SlotRightHand) || ev["slot"] != float64(0) {
		t.Errorf("%s reads %+v, want the sword coming from %q into slot 0", game.EvUnequip, ev, game.SlotRightHand)
	}
}

func TestUnequipFillsTheLowestFreeSlotRatherThanTheOneItLeft(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindAcorn, game.KindSword})

	alice := h.dial("alice")
	alice.welcome()

	alice.equip(1)
	h.awaitEvents(game.EvEquip, 1)
	alice.drop(0)
	h.awaitEvents(game.EvDrop, 1)
	alice.drain()

	alice.unequip(game.SlotRightHand)
	h.awaitEvents(game.EvUnequip, 1)

	held := alice.awaitInventory()
	if len(held.Slots) != 1 {
		t.Fatalf("alice holds %+v, want just the sword", held.Slots)
	}
	if got := held.Slots[0]; got.Slot != 0 {
		t.Fatalf("the sword came back to slot %d, want slot 0: an unequip fills the lowest free slot, not the one it vacated", got.Slot)
	}
}

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

	alice.expectSilence()

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
			h := newHarnessWithKit(t, []string{game.KindSword})
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

func TestUnequippingIntoAFullBagIsRefusedAndTheSwordStaysWorn(t *testing.T) {
	h := newHarnessWithKit(t, fullBagKit(), acornAt(0, 0))

	alice := h.dial("alice")
	world := alice.welcome()
	underfoot := world.Items[0].ID

	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.pickup(underfoot)
	h.awaitEvents(game.EvPickupResolved, 1)

	full := alice.awaitInventory()
	if len(full.Slots) != game.InventorySize {
		t.Fatalf("the bag holds %d of %d slots, want it full before the unequip is attempted", len(full.Slots), game.InventorySize)
	}
	alice.drain()

	alice.unequip(game.SlotRightHand)

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

	for _, f := range alice.collect(silenceWindow) {
		t.Errorf("a refused unequip sent alice a %s frame: %s", f.kind(), f.raw)
	}
	if snapshot := h.dial("charlie").welcomeFrame(); len(snapshot.Items) != 0 {
		t.Fatalf("the world holds %+v after a refused unequip; the sword was dropped rather than kept", snapshot.Items)
	}
	if spawns := h.eventsNamed(game.EvItemSpawned); len(spawns) != 1 {
		t.Fatalf("logged %d %s events, want only the one seeded acorn: %+v", len(spawns), game.EvItemSpawned, spawns)
	}

	alice.destroy()
	resumed := readJoinStep(h.dialResume("alice-again", world.Session))
	kind, wearing := wornKind(resumed.equipment, game.SlotRightHand)
	if !wearing || kind != game.KindSword {
		t.Fatalf("alice is wearing %+v after the refusal, want the sword still on", resumed.equipment.Slots)
	}
	if len(resumed.inventory.Slots) != game.InventorySize {
		t.Fatalf("alice's bag holds %d slots after the refusal, want the same full %d", len(resumed.inventory.Slots), game.InventorySize)
	}
}

func TestUnequipRefusalsNameTheirReasonAndChangeNothing(t *testing.T) {
	cases := []struct {
		name string
		worn mnet.EquipSlot
		want mnet.RejectReason
	}{
		{"a slot this server does not have", "cape", mnet.ReasonNoSuchWornSlot},
		{"a name that is no name at all", "", mnet.ReasonNoSuchWornSlot},
		{"the wrong case", "WEAPON", mnet.ReasonNoSuchWornSlot},
		{"a slot it has, wearing nothing", game.SlotRightHand, mnet.ReasonEmptyWornSlot},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarnessWithKit(t, []string{game.KindSword})
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

func TestUnequipNamingABagIndexIsRefusedAsAMissingField(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword})
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

func TestEquippingOntoAWornSwordSwapsThroughTheVacatedSlot(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword, game.KindSword})

	alice := h.dial("alice")
	alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.equip(1)
	h.awaitEvents(game.EvEquip, 2)

	frames := alice.collect(silenceWindow)
	if kinds := countKinds(frames); kinds["inventory"] != 1 || kinds["equipment"] != 1 || kinds["class"] != 1 || len(frames) != 3 {
		t.Fatalf("a swap sent %v, want one inventory, one equipment and one class", kinds)
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

	if len(worn.Slots) != 1 || worn.Slots[0].Kind != game.KindSword {
		t.Fatalf("alice is wearing %+v, want the one sword the swap put on", worn.Slots)
	}
	if len(held.Slots) != 1 {
		t.Fatalf("alice's bag holds %+v, want exactly the displaced axe: two axes went in, two must come out", held.Slots)
	}
	if got := held.Slots[0]; got.Slot != 1 || got.Kind != game.KindSword {
		t.Fatalf("the displaced axe is %q in slot %d, want a sword in slot 1, the one the new axe left", got.Kind, got.Slot)
	}

	swapped := h.eventsNamed(game.EvEquip)
	if got := swapped[1]["displaced"]; got != game.KindSword {
		t.Errorf("%s reads displaced %v, want %q: the field is the whole record that a swap happened", game.EvEquip, got, game.KindSword)
	}
}

func TestWornEquipmentSurvivesSuspendAndResume(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword})

	alice := h.dial("alice")
	first := alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)

	before := alice.awaitEquipmentBeforeDeath(t)

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)

	resumed := readJoinStep(h.dialResume("alice-again", first.Session))
	if resumed.welcome.You != first.You {
		t.Fatalf("the resume was handed player %d, want %d back", resumed.welcome.You, first.You)
	}

	kind, wearing := wornKind(resumed.equipment, game.SlotRightHand)
	if !wearing {
		t.Fatalf("the resumed player is wearing %+v, want the sword it had on when the socket died", resumed.equipment.Slots)
	}
	if kind != before {
		t.Fatalf("the resumed player is wearing %q, want the %q it had on before", kind, before)
	}
	if len(resumed.equipment.Slots) != 1 {
		t.Fatalf("the resumed player is wearing %+v, want exactly one thing: a resume that duplicates is as wrong as one that loses", resumed.equipment.Slots)
	}
	if len(resumed.inventory.Slots) != 0 {
		t.Fatalf("the resumed bag holds %+v, want it empty: the sword is worn, and a copy in the bag is a dupe", resumed.inventory.Slots)
	}
	if len(resumed.equipment.Worn) != len(game.WornSlots) {
		t.Errorf("the resumed equipment names slots %v, want the server's list %v", resumed.equipment.Worn, game.WornSlots)
	}
}

func (c *client) awaitEquipmentBeforeDeath(t *testing.T) string {
	t.Helper()

	deadline := silenceWindow
	for _, f := range c.collect(deadline) {
		if f.Equipment == nil {
			continue
		}
		if kind, wearing := wornKind(*f.Equipment, game.SlotRightHand); wearing {
			return kind
		}
	}
	t.Fatalf("client %s: no equipment naming a worn %q arrived", c.name, game.SlotRightHand)
	return ""
}

func TestWornEquipmentDiesWithThePlayer(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword})

	alice := h.dial("alice")
	first := alice.welcome()
	alice.equip(0)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.close()
	h.awaitEvents(game.EvDisconnected, 1)

	fresh := readJoinStep(h.dialResume("alice-again", first.Session))
	if fresh.welcome.You == first.You {
		t.Fatalf("a logged-out player's token was handed back player %d", fresh.welcome.You)
	}
	if len(fresh.equipment.Slots) != 0 {
		t.Fatalf("a fresh player is wearing %+v, want nothing: worn equipment dies with the player", fresh.equipment.Slots)
	}
	if len(fresh.inventory.Slots) != 1 || fresh.inventory.Slots[0].Kind != game.KindSword {
		t.Fatalf("a fresh player holds %+v, want the one sword of its own kit", fresh.inventory.Slots)
	}
}

func TestASequencedEquipIsDedupedAndLogsItsSeq(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindSword})

	alice := h.dial("alice")
	alice.welcome()
	alice.drain()

	alice.sendRaw(`{"equip":{"slot":0,"seq":4}}`)
	h.awaitEvents(game.EvEquip, 1)
	alice.drain()

	alice.sendRaw(`{"equip":{"slot":0,"seq":4}}`)
	h.awaitEvents(game.EvIntentDuplicate, 1)

	if got := h.eventsNamed(game.EvEquip); len(got) != 1 {
		t.Fatalf("logged %d %s events for one number sent twice, want 1: %+v", len(got), game.EvEquip, got)
	}
	if got := h.eventsNamed(game.EvEquip)[0]["seq"]; got != float64(4) {
		t.Errorf("%s reads seq %v, want 4", game.EvEquip, got)
	}
	alice.expectSilence()
}

func TestATwoHandedEquipRestatesBothHands(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindStaff})

	alice := h.dial("alice")
	alice.welcome()
	alice.drain()

	alice.sendRaw(`{"equip":{"slot":0}}`)
	h.awaitEvents(game.EvEquip, 1)

	alice.awaitInventory()
	eq := alice.equipment()
	seen := make(map[mnet.EquipSlot]string)
	for _, s := range eq.Slots {
		seen[s.Slot] = s.Kind
	}
	if seen[game.SlotLeftHand] != game.KindStaff || seen[game.SlotRightHand] != game.KindStaff {
		t.Fatalf("the restatement shows %v, want %q in both hand slots", seen, game.KindStaff)
	}
}
