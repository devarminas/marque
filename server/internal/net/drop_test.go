package net_test

// drop, driven through real WebSocket clients against a real server. It is
// pickup's reverse transaction, so most of what is worth asserting here is a
// mirror of items_test.go: one atomic move, everyone told including the causer,
// and a refusal that broadcasts nothing.
//
// It is also the first runtime caller of the item-spawn path. M1a seeded every
// item before any connection existed, so item_spawn had never crossed a socket
// and the include-the-causer rule had never been exercised by anything but the
// type system.

import (
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// underfoot is the spawn point, where every player enters the world.
//
// It is zero rather than something merely inside PickupRange, and the
// difference matters: PickupRange governs resolution only, so an item a
// fraction of a unit away is still walked to and the player ends up standing on
// it. An item at zero distance is the degenerate case that assigns no path at
// all and resolves on the next tick (PROTOCOL.md, "Pickup").
//
// These tests use it to get an item into an inventory without spending a walk
// on it, and, for the drop tests, to know exactly where the dropper is: she
// never moves.
const underfoot = 0.0

// TestDropIsImmediateAndReachesEveryoneIncludingTheDropper is the unit in one
// test: the item leaves the slot and lands at the player's feet on that tick,
// item_spawn goes to everybody, and only the dropper's inventory is restated.
//
// The frames are asserted as a whole set rather than one at a time, because
// three of the four claims are about what did *not* arrive: no path, because a
// drop is not a walk; nothing else to the dropper; and nothing but the spawn to
// the observer.
func TestDropIsImmediateAndReachesEveryoneIncludingTheDropper(t *testing.T) {
	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	seeded := alice.welcome().Items[0].ID

	bob := h.dial("bob")
	bob.welcome()
	alice.spawn() // bob joining

	alice.pickup(seeded)
	held := alice.awaitInventory()
	if len(held.Slots) != 1 {
		t.Fatalf("alice holds %+v before the drop, want one acorn", held.Slots)
	}
	alice.drain()
	bob.drain()

	alice.drop(held.Slots[0].Slot)

	// The dropper's whole share of the transaction: the world's change, then
	// the one message that is private to her.
	mine := alice.collect(silenceWindow)
	if len(mine) != 2 || mine[0].ItemSpawn == nil || mine[1].Inventory == nil {
		t.Fatalf("the dropper received %d frames %v, want exactly an item_spawn then an inventory",
			len(mine), kindsOf(mine))
	}
	spawned := *mine[0].ItemSpawn
	if got := *mine[1].Inventory; len(got.Slots) != 0 {
		t.Fatalf("the dropper's new inventory holds %+v, want nothing", got.Slots)
	}

	// The observer's share: the same announcement, and nothing else. An
	// inventory here would be one player's private state broadcast to another.
	theirs := bob.collect(silenceWindow)
	if len(theirs) != 1 || theirs[0].ItemSpawn == nil {
		t.Fatalf("the observer received %d frames %v, want exactly one item_spawn",
			len(theirs), kindsOf(theirs))
	}
	if *theirs[0].ItemSpawn != spawned {
		t.Fatalf("the observer was told %+v and the dropper %+v; one broadcast, one payload",
			*theirs[0].ItemSpawn, spawned)
	}

	// At the player's feet, which is the spawn point: alice has never moved.
	if spawned.Kind != game.KindAcorn || spawned.X != 0 || spawned.Z != 0 {
		t.Fatalf("the item landed as %+v, want an acorn at the dropper's feet (0, 0)", spawned)
	}
	if spawned.ID == seeded {
		t.Fatalf("the dropped item came back as id %d, which the taken item already had: "+
			"ids are never reused within a process", spawned.ID)
	}

	// One transaction, one tick. Nothing pending, and no path was chosen,
	// which is the whole of "drop is immediate".
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
	// The seed's entry carries no causer, so neither may the drop's: one event
	// name, one field set (world.go, EvItemSpawned).
	if _, has := entered[1]["player"]; has {
		t.Errorf("%s carries a player field for a drop and none for a seed: %+v", game.EvItemSpawned, entered[1])
	}
}

// TestDroppingWhileWalkingLandsTheItemUnderfootAndTheWalkGoesOn. Dropping mid
// walk is legal, the item lands where the player is at that tick rather than at
// the end of the path, and nothing about the walk changes.
func TestDroppingWhileWalkingLandsTheItemUnderfootAndTheWalkGoesOn(t *testing.T) {
	// Far enough that the drop happens with most of the path still ahead, near
	// enough that the walk costs the suite about a second.
	const destination = 4.0

	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	seeded := alice.welcome().Items[0].ID
	alice.pickup(seeded)
	slot := alice.awaitInventory().Slots[0].Slot
	alice.drain()

	alice.moveTo(destination, 0)
	if walk := alice.path(); len(walk.Points) != 2 {
		t.Fatalf("the walk is %+v, want a two-point polyline to drop in the middle of", walk.Points)
	}

	// Two ticks, so the player is demonstrably no longer where the walk began
	// and demonstrably not yet where it ends. The suite has no finer clock than
	// this; the tick loop is the only thing that advances a walker.
	time.Sleep(2 * game.TickDuration)
	alice.drop(slot)

	// The walk runs to completion. Nothing halted her, and nothing replaced her
	// path, which the frame set below is what proves.
	h.awaitEvents(game.EvArrived, 1)

	frames := alice.collect(silenceWindow)
	if len(frames) != 2 || frames[0].ItemSpawn == nil || frames[1].Inventory == nil {
		t.Fatalf("a drop mid-walk produced %d frames %v, want an item_spawn and an inventory; "+
			"a path among them would mean the drop disturbed the walk", len(frames), kindsOf(frames))
	}
	spawned := *frames[0].ItemSpawn

	if spawned.X <= 0 || spawned.X >= destination {
		t.Fatalf("the item landed at x=%v, want it strictly between the start of the walk (0) and "+
			"its end (%v): a drop lands at the player's position now, not at the destination",
			spawned.X, destination)
	}
	if spawned.Z != 0 {
		t.Fatalf("the item landed at z=%v, want 0: the walk never leaves the x axis", spawned.Z)
	}

	// The broadcast and the world agree. A joiner is told about the item from
	// world state rather than from the frame, so this is a second source for
	// the same coordinates.
	bob := h.dial("bob")
	items := bob.welcome().Items
	if len(items) != 1 {
		t.Fatalf("a joiner sees %+v, want the one dropped item", items)
	}
	if items[0].ID != spawned.ID || items[0].X != spawned.X || items[0].Z != spawned.Z {
		t.Fatalf("the joiner is told %+v and the broadcast said %+v", items[0], spawned)
	}
}

// TestARefusedDropIsAnsweredOnceAndBroadcastsNothing covers both refusals the
// protocol names: an index outside 0 to size-1, and a legal index holding
// nothing. Each gets one error and nothing else, and no observer hears a thing.
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

	// One error each and nothing more. The observer heard nothing at all,
	// which is the half no positive assertion can show.
	alice.expectSilence()
	bob.expectSilence()

	// Every refusal left the inventory alone, so the acorn is still there to
	// drop for real.
	alice.drop(0)
	if inv := alice.awaitInventory(); len(inv.Slots) != 0 {
		t.Fatalf("after five refusals and one real drop alice holds %+v, want nothing", inv.Slots)
	}
}

// TestADroppedItemCanBePickedUpAgain is the unit's reason to exist: drop is
// pickup's reverse, so the round trip must return the inventory to what it was.
//
// It also pins the one thing that does not come back. Ids are never reused, and
// an inventory holds kinds rather than ids, so the item that comes back is a new
// item as far as every client is concerned.
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

	// The item is under her feet, so this pickup assigns no path either.
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

// TestAJoinerRacingADropIsToldAboutTheItemExactlyOnce is the ordering rule the
// atomic welcome step exists for, applied to the first message that can race it.
//
// welcome.items and a live item_spawn describe the same thing, so a joiner must
// get exactly one of them for any one item: both is a duplicated body, neither
// is a body the client never learns about. Which one it gets is decided by
// whether the drop was handled before or after the join step, and both answers
// are correct.
func TestAJoinerRacingADropIsToldAboutTheItemExactlyOnce(t *testing.T) {
	const races = 1
	const drops = races + 2 // one forced each way, plus the unforced race

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

	// Forced: the drop is complete before the joiner exists, so the item is
	// world state by the time the welcome is composed and the broadcast went
	// out to a world the joiner was not in.
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

	// Forced the other way: the joiner is in the world before the drop, so the
	// welcome cannot have named the item and the broadcast must reach her.
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

	// Unforced: the drop frame is written and the dial follows immediately,
	// with no barrier between them, so nothing in the test decides which the
	// world goroutine handles first. The invariant is what is asserted, not the
	// outcome.
	//
	// In practice it is not a fair coin and the log line below says which way it
	// fell. A frame on an open socket reaches the read pump in a fraction of the
	// time a fresh WebSocket handshake takes, so the drop wins essentially
	// always. The two subtests above are what actually cover both orderings;
	// this one covers the interleaving neither of them has, where no wait for a
	// log line has quiesced the server first.
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
		// Logged rather than asserted: which side won is exactly what this
		// test does not get to decide. It is worth reading under -v, because a
		// run where every race landed the same way has exercised one ordering
		// and reported on two.
		heard := "the live item_spawn, so the join was handled first"
		if fromWelcome == 1 {
			heard = "welcome.items, so the drop was handled first"
		}
		t.Logf("race %d: the joiner learned about item %d from %s", i, item.ID, heard)
	}
}

// TestTwoPendingPickupsForDifferentItemsResolveInOnePass. Every M1a contest
// test has exactly one item in the world, so nothing yet showed that one pass
// can settle two independent pickups rather than one.
//
// The two intents have to land inside one tick for the two walks to end
// together, so the test starts them from an observed tick boundary the way
// TestBothRacersArriveOnTheSameTick does.
func TestTwoPendingPickupsForDifferentItemsResolveInOnePass(t *testing.T) {
	// One staging point, and two items the same distance from it in different
	// directions, so neither walker has a head start on the other.
	const staging = 1.0
	const reach = 2.0

	h := newHarness(t, acornAt(staging+reach, 0), acornAt(staging, reach))

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn()

	east, south := aliceWelcome.Items[0].ID, aliceWelcome.Items[1].ID

	alice.moveTo(staging, 0)
	bob.moveTo(staging, 0)
	h.awaitEvents(game.EvArrived, 2)
	alice.drain()
	bob.drain()

	alice.pickup(east)
	bob.pickup(south)

	paths := h.awaitEvents(game.EvPathAssigned, 4) // two staging walks, two pickups
	if paths[2]["start_tick"] != paths[3]["start_tick"] {
		t.Fatalf("the two pickups were assigned paths at ticks %v and %v, so a tick boundary fell "+
			"between them and the walks cannot end together", paths[2]["start_tick"], paths[3]["start_tick"])
	}

	resolved := h.awaitEvents(game.EvPickupResolved, 2)
	if resolved[0]["t"] != resolved[1]["t"] {
		t.Fatalf("the two pickups resolved on ticks %v and %v; equidistant walkers heading for "+
			"different items must settle in one pass", resolved[0]["t"], resolved[1]["t"])
	}

	// Each took the item they asked for. Resolution is in join order, so alice
	// is first in the pass and her item is first in the log.
	want := []struct {
		player mnet.PlayerID
		item   mnet.ItemID
	}{
		{aliceWelcome.You, east},
		{bobWelcome.You, south},
	}
	for i, w := range want {
		if got := resolved[i]["player"]; got != float64(w.player) {
			t.Errorf("resolution %d is for player %v, want %d", i, got, w.player)
		}
		if got := resolved[i]["item"]; got != float64(w.item) {
			t.Errorf("resolution %d hands over item %v, want %d", i, got, w.item)
		}
	}

	// Two items and two takers is not a contest, so nobody lost.
	if lost := h.eventsNamed(game.EvPickupLost); len(lost) != 0 {
		t.Errorf("%d players lost a pickup for two items nobody was competing over: %+v", len(lost), lost)
	}
}

// TestANearerLaterJoinerTakesItFromAnEarlierPlayerOutOfRange separates the two
// readings of the contest rule that M1a's tests cannot tell apart.
//
// Every M1a contest has both players in range at once, where join order decides.
// This one has the earlier joiner still walking and out of range in the pass
// that the later joiner, standing on the item, resolves in. If join order were
// absolute priority the earlier player would win by waiting; it is a tiebreaker
// among the players who can actually reach the item, so the nearer one takes it.
func TestANearerLaterJoinerTakesItFromAnEarlierPlayerOutOfRange(t *testing.T) {
	// Far enough that alice needs several ticks to walk back into range, which
	// bob does not need at all.
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

	alice.moveTo(away, 0)
	h.awaitEvents(game.EvArrived, 1)
	alice.drain()
	bob.drain()

	// Alice asks first, and her path frame is what proves the server has
	// already recorded her pending pickup. Bob asks second, from on top of the
	// item, and resolves on the next tick while she is still walking.
	alice.pickup(item)
	alice.path()
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

// TestDecodeDrop is the wire body, including the compatibility rule that lets
// senders add fields the body does not name.
func TestDecodeDrop(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name  string
		frame string
		want  int
	}{
		{"plain", `{"drop":{"slot":3}}`, 3},
		// Slot 0 is the first slot RuneScape's lowest-free rule fills, so
		// "absent" and "zero" have to stay distinguishable here.
		{"the first slot", `{"drop":{"slot":0}}`, 0},
		{"the last slot", `{"drop":{"slot":27}}`, 27},
		// Out of range is a question about world state, not about the frame.
		// The decoder hands it on and the game package refuses it.
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

// TestDecodeDropRejections. A broken body is a broken frame, not a broken
// client, so every one of these survives the connection.
func TestDecodeDropRejections(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		frame  string
		reason mnet.RejectReason
	}{
		// Absent is not zero. Left to encoding/json this would drop whatever
		// is in the player's first slot.
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

// TestAMalformedDropIsRefusedWithoutClosing keeps drop on the same footing as
// move_to and pickup at the layer that answers a real socket, and pins that the
// refusals are filed under drop's own event name rather than move_to's.
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

	// Still a working client, and still able to pick something up and put it
	// back down.
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

// listsItem reports whether a welcome's world snapshot named one item.
func listsItem(items []mnet.ItemState, id mnet.ItemID) bool {
	for _, item := range items {
		if item.ID == id {
			return true
		}
	}
	return false
}

// kindsOf names a set of frames, for a failure message about what arrived
// rather than about what one frame contained.
func kindsOf(frames []frame) []string {
	kinds := make([]string, 0, len(frames))
	for _, f := range frames {
		kinds = append(kinds, f.kind())
	}
	return kinds
}
