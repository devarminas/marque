package net_test


import (
	"math"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const underfoot = 0.0

func TestDropIsImmediateAndReachesEveryoneIncludingTheDropper(t *testing.T) {
	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	seeded := alice.welcome().Items[0].ID

	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.pickup(seeded)
	held := alice.awaitInventory()
	if len(held.Slots) != 1 {
		t.Fatalf("alice holds %+v before the drop, want one acorn", held.Slots)
	}
	alice.drain()
	bob.drain()

	alice.drop(held.Slots[0].Slot)

	mine := alice.collect(silenceWindow)
	if len(mine) != 2 || mine[0].ItemSpawn == nil || mine[1].Inventory == nil {
		t.Fatalf("the dropper received %d frames %v, want exactly an item_spawn then an inventory",
			len(mine), kindsOf(mine))
	}
	spawned := *mine[0].ItemSpawn
	if got := *mine[1].Inventory; len(got.Slots) != 0 {
		t.Fatalf("the dropper's new inventory holds %+v, want nothing", got.Slots)
	}

	theirs := bob.collect(silenceWindow)
	if len(theirs) != 1 || theirs[0].ItemSpawn == nil {
		t.Fatalf("the observer received %d frames %v, want exactly one item_spawn",
			len(theirs), kindsOf(theirs))
	}
	if *theirs[0].ItemSpawn != spawned {
		t.Fatalf("the observer was told %+v and the dropper %+v; one broadcast, one payload",
			*theirs[0].ItemSpawn, spawned)
	}

	if spawned.Kind != game.KindAcorn || spawned.X != 0 || spawned.Z != 0 {
		t.Fatalf("the item landed as %+v, want an acorn at the dropper's feet (0, 0)", spawned)
	}
	if spawned.ID == seeded {
		t.Fatalf("the dropped item came back as id %d, which the taken item already had: "+
			"ids are never reused within a process", spawned.ID)
	}

	dropped := h.awaitEvents(game.EvDrop, 1)
	entered := h.eventsNamed(game.EvItemSpawned)
	if len(entered) != 2 {
		t.Fatalf("%d %s events, want 2: the seed and the drop", len(entered), game.EvItemSpawned)
	}
	if dropped[0]["t"] != entered[1]["t"] {
		t.Errorf("the drop is logged on tick %v and the item entering the world on tick %v; "+
			"one transaction must not straddle a tick", dropped[0]["t"], entered[1]["t"])
	}
	if got := dropped[0]["slot"]; got != float64(held.Slots[0].Slot) {
		t.Errorf("%s names slot %v, want %d", game.EvDrop, got, held.Slots[0].Slot)
	}
	if got := dropped[0]["item"]; got != float64(spawned.ID) {
		t.Errorf("%s names item %v, want %d", game.EvDrop, got, spawned.ID)
	}
	if got := dropped[0]["kind"]; got != game.KindAcorn {
		t.Errorf("%s names kind %v, want %q", game.EvDrop, got, game.KindAcorn)
	}
	if _, has := entered[1]["player"]; has {
		t.Errorf("%s carries a player field for a drop and none for a seed: %+v", game.EvItemSpawned, entered[1])
	}
}

func TestDroppingWhileWalkingLandsTheItemUnderfootAndTheWalkGoesOn(t *testing.T) {
	const destination = 4.0

	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	seeded := alice.welcome().Items[0].ID
	alice.pickup(seeded)
	slot := alice.awaitInventory().Slots[0].Slot
	alice.drain()

	alice.move(1, 0)
	alice.awaitPose()

	time.Sleep(2 * game.TickDuration)
	alice.drop(slot)

	frames := alice.collect(silenceWindow)
	var spawned *mnet.ItemSpawn
	var sawInv bool
	for _, f := range frames {
		switch {
		case f.ItemSpawn != nil:
			spawned = f.ItemSpawn
		case f.Inventory != nil:
			sawInv = true
		case f.Pose != nil:
			continue
		default:
			t.Fatalf("unexpected frame mid-drop: %s", f.raw)
		}
	}
	if spawned == nil || !sawInv {
		t.Fatalf("a drop mid-walk produced %d frames %v, want item_spawn and inventory", len(frames), kindsOf(frames))
	}

	if spawned.X <= 0 || spawned.X >= destination {
		t.Fatalf("the item landed at x=%v, want it strictly between the start of the walk (0) and "+
			"its end (%v): a drop lands at the player's position now, not at the destination",
			spawned.X, destination)
	}
	if spawned.Z != 0 {
		t.Fatalf("the item landed at z=%v, want 0: the walk never leaves the x axis", spawned.Z)
	}

	bob := h.dial("bob")
	items := bob.welcome().Items
	if len(items) != 1 {
		t.Fatalf("a joiner sees %+v, want the one dropped item", items)
	}
	if items[0].ID != spawned.ID || items[0].X != spawned.X || items[0].Z != spawned.Z {
		t.Fatalf("the joiner is told %+v and the broadcast said %+v", items[0], spawned)
	}
}

func TestARefusedDropIsAnsweredOnceAndBroadcastsNothing(t *testing.T) {
	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	seeded := alice.welcome().Items[0].ID

	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.pickup(seeded)
	held := alice.awaitInventory()
	if len(held.Slots) != 1 || held.Slots[0].Slot != 0 {
		t.Fatalf("alice holds %+v, want the acorn in slot 0", held.Slots)
	}
	alice.drain()
	bob.drain()

	cases := []struct {
		name string
		slot int
		want mnet.RejectReason
	}{
		{"one past the last slot", game.InventorySize, mnet.ReasonNoSuchSlot},
		{"negative", -1, mnet.ReasonNoSuchSlot},
		{"far outside the grid", 1 << 20, mnet.ReasonNoSuchSlot},
		{"an empty slot in range", 1, mnet.ReasonEmptySlot},
		{"the last slot, empty", game.InventorySize - 1, mnet.ReasonEmptySlot},
	}
	for _, tc := range cases {
		alice.drop(tc.slot)
		if refusal := alice.errorFrame(); refusal.Re != mnet.MsgDrop {
			t.Fatalf("%s: the error is attributed to %q, want %q", tc.name, refusal.Re, mnet.MsgDrop)
		}
	}

	rejected := h.awaitEvents(game.EvDropRejected, len(cases))
	for i, tc := range cases {
		if got := rejected[i]["reason"]; got != string(tc.want) {
			t.Errorf("%s was rejected with %v, want %q", tc.name, got, tc.want)
		}
	}

	alice.expectSilence()
	bob.expectSilence()

	alice.drop(0)
	if inv := alice.awaitInventory(); len(inv.Slots) != 0 {
		t.Fatalf("after five refusals and one real drop alice holds %+v, want nothing", inv.Slots)
	}
}

func TestADroppedItemCanBePickedUpAgain(t *testing.T) {
	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	seeded := alice.welcome().Items[0].ID

	alice.pickup(seeded)
	before := alice.awaitInventory()

	alice.drop(before.Slots[0].Slot)
	dropped := alice.awaitItemSpawn()
	if emptied := alice.awaitInventory(); len(emptied.Slots) != 0 {
		t.Fatalf("after the drop alice holds %+v, want nothing", emptied.Slots)
	}

	alice.pickup(dropped.ID)
	alice.awaitItemDespawn(dropped.ID)
	after := alice.awaitInventory()

	if after.Size != before.Size || len(after.Slots) != len(before.Slots) {
		t.Fatalf("the inventory came back as %+v, want the %+v it started as", after, before)
	}
	if after.Slots[0] != before.Slots[0] {
		t.Fatalf("the item came back to %+v, want the %+v it left from", after.Slots[0], before.Slots[0])
	}
	if dropped.ID == seeded {
		t.Fatalf("the round trip reused item id %d", seeded)
	}

	if items := h.dial("bob").welcome().Items; len(items) != 0 {
		t.Fatalf("after a drop and a pickup the ground holds %+v, want nothing", items)
	}
}

func TestAJoinerRacingADropIsToldAboutTheItemExactlyOnce(t *testing.T) {
	const races = 1
	const drops = races + 2

	seeds := make([]seed, 0, drops)
	for range drops {
		seeds = append(seeds, acornAt(underfoot, 0))
	}
	h := newHarness(t, seeds...)

	alice := h.dial("alice")
	world := alice.welcome()
	for _, item := range world.Items {
		alice.pickup(item.ID)
		alice.awaitItemDespawn(item.ID)
	}
	if held := alice.awaitInventory(); len(held.Slots) != drops {
		t.Fatalf("alice holds %d items, want the %d she picked up", len(held.Slots), drops)
	}
	alice.drain()

	slot := 0
	nextDrop := func() mnet.ItemSpawn {
		t.Helper()
		alice.drop(slot)
		slot++
		return alice.awaitItemSpawn()
	}

	t.Run("joining after the drop", func(t *testing.T) {
		item := nextDrop()
		h.awaitEvents(game.EvDrop, slot)

		carol := h.dial("carol")
		if !listsItem(carol.welcomeFrame().Items, item.ID) {
			t.Errorf("item %d was dropped before carol joined and is not in her welcome", item.ID)
		}
		if got := carol.countItemSpawns(item.ID, silenceWindow); got != 0 {
			t.Errorf("carol was sent %d item_spawn frames for item %d, which her welcome already "+
				"described: the body would be built twice", got, item.ID)
		}
	})

	t.Run("joining before the drop", func(t *testing.T) {
		dave := h.dial("dave")
		joined := dave.welcomeFrame()
		dave.drain()

		item := nextDrop()
		if listsItem(joined.Items, item.ID) {
			t.Fatalf("dave's welcome named item %d before it had been dropped", item.ID)
		}
		if got := dave.countItemSpawns(item.ID, silenceWindow); got != 1 {
			t.Errorf("dave was sent %d item_spawn frames for item %d, want exactly 1", got, item.ID)
		}
	})

	for i := range races {
		alice.drop(slot)
		slot++
		racer := h.dial("racer")

		item := alice.awaitItemSpawn()
		fromWelcome := 0
		if listsItem(racer.welcomeFrame().Items, item.ID) {
			fromWelcome = 1
		}
		live := racer.countItemSpawns(item.ID, silenceWindow)

		if fromWelcome+live != 1 {
			t.Fatalf("race %d: item %d was described to the joiner %d times in welcome and %d times "+
				"live, want exactly 1 in total", i, item.ID, fromWelcome, live)
		}
		heard := "the live item_spawn, so the join was handled first"
		if fromWelcome == 1 {
			heard = "welcome.items, so the drop was handled first"
		}
		t.Logf("race %d: the joiner learned about item %d from %s", i, item.ID, heard)
	}
}

func TestTwoPendingPickupsForDifferentItemsResolveInOnePass(t *testing.T) {
	const staging = 1.0
	const reach = 2.0

	h := newHarness(t, acornAt(staging+reach, 0), acornAt(staging, reach))

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn()

	east, south := aliceWelcome.Items[0].ID, aliceWelcome.Items[1].ID

	alice.walkTo(staging, 0)
	bob.walkTo(staging, 0)
	alice.drain()
	bob.drain()

	alice.pickup(east)
	bob.pickup(south)

	resolved := h.awaitEvents(game.EvPickupResolved, 2)
	if math.Abs(resolved[0]["t"].(float64)-resolved[1]["t"].(float64)) > 2 {
		t.Fatalf("the two pickups resolved on ticks %v and %v; equidistant steers heading for "+
			"different items must settle within two ticks", resolved[0]["t"], resolved[1]["t"])
	}

	want := map[mnet.PlayerID]mnet.ItemID{
		aliceWelcome.You: east,
		bobWelcome.You:   south,
	}
	got := make(map[mnet.PlayerID]mnet.ItemID, 2)
	for _, ev := range resolved {
		got[mnet.PlayerID(ev["player"].(float64))] = mnet.ItemID(ev["item"].(float64))
	}
	for player, item := range want {
		if got[player] != item {
			t.Errorf("player %d resolved item %d, want %d (got map %#v)", player, got[player], item, got)
		}
	}

	if lost := h.eventsNamed(game.EvPickupLost); len(lost) != 0 {
		t.Errorf("%d players lost a pickup for two items nobody was competing over: %+v", len(lost), lost)
	}
}

func TestANearerLaterJoinerTakesItFromAnEarlierPlayerOutOfRange(t *testing.T) {
	const away = 3.0

	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn()

	if aliceWelcome.You >= bobWelcome.You {
		t.Fatalf("alice is player %d and bob is player %d; this test needs alice to have joined first",
			aliceWelcome.You, bobWelcome.You)
	}
	item := aliceWelcome.Items[0].ID

	alice.walkTo(away, 0)
	alice.drain()
	bob.drain()

	alice.pickup(item)
	_ = alice.awaitPlayerPose(aliceWelcome.You)
	bob.pickup(item)

	resolved := h.awaitEvents(game.EvPickupResolved, 1)
	if got := resolved[0]["player"]; got != float64(bobWelcome.You) {
		t.Fatalf("item %d went to player %v, want bob (%d): the earlier joiner was out of range, "+
			"and join order is a tiebreaker among the players who can reach the item, not a priority "+
			"that outranks distance", item, got, bobWelcome.You)
	}

	lost := h.awaitEvents(game.EvPickupLost, 1)
	if got := lost[0]["player"]; got != float64(aliceWelcome.You) {
		t.Fatalf("%s names player %v, want alice (%d)", game.EvPickupLost, got, aliceWelcome.You)
	}
	if resolved[0]["t"].(float64) > lost[0]["t"].(float64) {
		t.Errorf("bob took the item on tick %v and alice learned it was gone on tick %v",
			resolved[0]["t"], lost[0]["t"])
	}

	if inv := bob.awaitInventory(); len(inv.Slots) != 1 || inv.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("bob holds %+v, want the acorn he was standing on", inv.Slots)
	}
	for _, f := range alice.collect(silenceWindow) {
		if f.Inventory != nil {
			t.Fatalf("alice's inventory was restated for a pickup she lost: %s", f.raw)
		}
	}
}

func TestDecodeDrop(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name  string
		frame string
		want  int
	}{
		{"plain", `{"drop":{"slot":3}}`, 3},
		{"the first slot", `{"drop":{"slot":0}}`, 0},
		{"the last slot", `{"drop":{"slot":27}}`, 27},
		{"outside the inventory", `{"drop":{"slot":-1}}`, -1},
		{"with a seq, which the envelope reads and the body ignores", `{"drop":{"slot":3,"seq":9}}`, 3},
		{"with a field nobody has invented yet", `{"drop":{"slot":3,"whatever":true}}`, 3},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, _, err := mnet.Decode([]byte(tc.frame))
			if err != nil {
				t.Fatalf("Decode(%s) failed: %v", tc.frame, err)
			}
			got, ok := msg.(mnet.Drop)
			if !ok {
				t.Fatalf("Decode(%s) returned %T, want Drop", tc.frame, msg)
			}
			if got.Slot != tc.want {
				t.Fatalf("Decode(%s) gave slot %d, want %d", tc.frame, got.Slot, tc.want)
			}
		})
	}
}

func TestDecodeDropRejections(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		frame  string
		reason mnet.RejectReason
	}{
		{"no slot", `{"drop":{}}`, mnet.ReasonMissingField},
		{"null payload", `{"drop":null}`, mnet.ReasonMissingField},
		{"a slot named by kind", `{"drop":{"slot":"acorn"}}`, mnet.ReasonMalformedJSON},
		{"a fractional slot", `{"drop":{"slot":1.5}}`, mnet.ReasonMalformedJSON},
		{"a slot that is an object", `{"drop":{"slot":{"item":1}}}`, mnet.ReasonMalformedJSON},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, _, err := mnet.Decode([]byte(tc.frame))
			if err == nil {
				t.Fatalf("Decode(%s) accepted the frame as %#v, want rejection %q", tc.frame, msg, tc.reason)
			}
			rejection, ok := mnet.Rejection(err)
			if !ok {
				t.Fatalf("Decode(%s) returned %v, which is not a rejection", tc.frame, err)
			}
			if rejection.Reason != tc.reason {
				t.Fatalf("Decode(%s) rejected with %q, want %q (%v)", tc.frame, rejection.Reason, tc.reason, err)
			}
			if rejection.Re != mnet.MsgDrop {
				t.Fatalf("Decode(%s) attributed to %q, want %q", tc.frame, rejection.Re, mnet.MsgDrop)
			}
			if rejection.Disposition != mnet.ReplyError {
				t.Fatalf("Decode(%s) disposition %v, want ReplyError: a broken body is not a broken client",
					tc.frame, rejection.Disposition)
			}
		})
	}
}

func TestAMalformedDropIsRefusedWithoutClosing(t *testing.T) {
	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	seeded := alice.welcome().Items[0].ID

	for _, frame := range []string{`{"drop":{}}`, `{"drop":{"slot":"first"}}`, `{"drop":{"slot":2.5}}`} {
		alice.sendRaw(frame)
		if refusal := alice.errorFrame(); refusal.Re != mnet.MsgDrop {
			t.Fatalf("%s: the error is attributed to %q, want %q", frame, refusal.Re, mnet.MsgDrop)
		}
	}
	h.awaitEvents(game.EvDropRejected, 3)

	alice.pickup(seeded)
	held := alice.awaitInventory()
	if len(held.Slots) != 1 {
		t.Fatalf("after three bad frames alice holds %+v, want the acorn", held.Slots)
	}
	alice.drop(held.Slots[0].Slot)
	if inv := alice.awaitInventory(); len(inv.Slots) != 0 {
		t.Fatalf("after the drop alice holds %+v, want nothing", inv.Slots)
	}
}

func listsItem(items []mnet.ItemState, id mnet.ItemID) bool {
	for _, item := range items {
		if item.ID == id {
			return true
		}
	}
	return false
}

func kindsOf(frames []frame) []string {
	kinds := make([]string, 0, len(frames))
	for _, f := range frames {
		kinds = append(kinds, f.kind())
	}
	return kinds
}
