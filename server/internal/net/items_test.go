package net_test

// Ground items, inventories, and the contested pickup, driven through real
// WebSocket clients against a real server. The file's reason to exist is
// TestTwoClientsRacingForOneItemLeaveExactlyOneHolder; everything above it
// exists so that when the race fails, something smaller has already failed and
// said why.

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// farItem is a seed position far enough from the spawn point that a pickup has
// to walk for several ticks to reach it. Ten units is twenty-two ticks of
// walking, which is long enough to observe a client mid-walk and short enough
// not to dominate the suite.
const farItem = 10.0

// TestWelcomeCarriesTheWorldAndThenTheInventory pins the join step's shape: the
// world's items ride in welcome beside its players, and the joining player's
// own inventory is a separate message, last.
func TestWelcomeCarriesTheWorldAndThenTheInventory(t *testing.T) {
	h := newHarness(t, acornAt(3, -2), acornAt(-4, 5))

	alice := h.dial("alice")
	welcome := alice.welcomeFrame()

	if len(welcome.Items) != 2 {
		t.Fatalf("welcome lists %d items, want the 2 that were seeded: %+v", len(welcome.Items), welcome.Items)
	}
	if welcome.Items[0].ID != 1 || welcome.Items[1].ID != 2 {
		t.Fatalf("welcome lists ids %d and %d, want 1 and 2 in seeding order", welcome.Items[0].ID, welcome.Items[1].ID)
	}
	if welcome.Items[0].Kind != game.KindAcorn || welcome.Items[0].X != 3 || welcome.Items[0].Z != -2 {
		t.Fatalf("first item is %+v, want an acorn at (3, -2)", welcome.Items[0])
	}
	// An item id is not a player id. Both spaces start at 1, and this is the
	// one message where both appear, so it is where a shared counter would be
	// visible.
	if welcome.You != 1 {
		t.Fatalf("the first player is %d, want 1: item ids must not consume player ids", welcome.You)
	}

	// The inventory is the next frame, because nobody is walking and the path
	// replays are therefore empty.
	inv := alice.inventory()
	if inv.Size != game.InventorySize {
		t.Fatalf("inventory size is %d, want %d", inv.Size, game.InventorySize)
	}
	if len(inv.Slots) != 0 {
		t.Fatalf("a fresh player starts holding %+v, want nothing", inv.Slots)
	}

	alice.expectSilence()
}

// TestAnEmptyWorldStillCarriesTheKeys keeps M0's behaviour with no -item flags
// and states what an empty array looks like on the wire, which is neither null
// nor an absent key.
func TestAnEmptyWorldStillCarriesTheKeys(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	welcome := alice.welcomeFrame()
	if len(welcome.Items) != 0 {
		t.Fatalf("an unseeded world reports %+v, want no items", welcome.Items)
	}

	inv := alice.awaitInventoryFrame()
	if !strings.Contains(inv.raw, `"slots":[]`) {
		t.Fatalf("an empty inventory encodes as %s, want \"slots\":[]", inv.raw)
	}
	if strings.Contains(inv.raw, "null") {
		t.Fatalf("inventory carries a null: %s", inv.raw)
	}
}

// TestPickupWalksThenTakes is RuneScape's answer to clicking an item, in one
// test: a path to the item, then the take, then the world and the player are
// both told.
func TestPickupWalksThenTakes(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	alice.pickup(item)

	// A path exactly as move_to assigns one: from where she is, to the item.
	assigned := alice.path()
	if assigned.ID != welcome.You {
		t.Fatalf("path is for player %d, want alice (%d)", assigned.ID, welcome.You)
	}
	if len(assigned.Points) != 2 {
		t.Fatalf("path has %d points, want a start and the item: %+v", len(assigned.Points), assigned.Points)
	}
	if assigned.Points[0] != mnet.Pt(0, 0) {
		t.Fatalf("path starts at %v, want alice's position (0, 0)", assigned.Points[0])
	}
	if assigned.Points[1] != mnet.Pt(farItem, 0) {
		t.Fatalf("path ends at %v, want the item at (%v, 0)", assigned.Points[1], farItem)
	}

	// Nothing has been taken yet: the item is still in the world for as long as
	// the walk lasts, which is what makes it contestable.
	gone := alice.awaitItemDespawn(item)
	if gone.ID != item {
		t.Fatalf("despawned item %d, want %d", gone.ID, item)
	}

	inv := alice.awaitInventory()
	if len(inv.Slots) != 1 {
		t.Fatalf("inventory holds %+v, want one acorn", inv.Slots)
	}
	if inv.Slots[0].Slot != 0 || inv.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("inventory holds %+v, want slot 0 with an acorn", inv.Slots[0])
	}

	resolved := h.awaitEvents(game.EvPickupResolved, 1)
	if got := resolved[0]["player"]; got != float64(welcome.You) {
		t.Fatalf("%s names player %v, want %d", game.EvPickupResolved, got, welcome.You)
	}

	alice.expectSilence()
}

// TestPickupOfTheItemUnderfootAssignsNoPath is the one place a pickup differs
// from a move_to at the same coordinates. A move_to that resolves to where the
// player is already standing is answered "already there"; a pickup has something
// left to do, so it is not an error, no path is assigned, nothing is broadcast,
// and the take happens on the next tick.
//
// The two cases are the whole of "underfoot", which is whatever MinPathLength
// calls the same spot. The second is the one that couples the two constants: no
// path is assigned, so nothing ever closes the gap that is left, and the take
// depends on PickupRange being at least MinPathLength. That is the only coupling
// PickupRange has left, it runs on a five-hundred-fold margin rather than the
// deleted carve-out's hundredth of a unit, and this is where it is held.
func TestPickupOfTheItemUnderfootAssignsNoPath(t *testing.T) {
	cases := []struct {
		name string
		x    float64
	}{
		{"exactly on it", 0},
		{"a hair off it", game.MinPathLength / 2},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t, acornAt(tc.x, 0))

			alice := h.dial("alice")
			welcome := alice.welcome()
			item := welcome.Items[0].ID

			alice.pickup(item)

			// The next frame is the despawn: no path, and no error either.
			f := alice.next()
			if f.ItemDespawn == nil {
				t.Fatalf("got a %s frame, want item_despawn with nothing before it: %s", f.kind(), f.raw)
			}
			if inv := alice.awaitInventory(); len(inv.Slots) != 1 {
				t.Fatalf("inventory holds %+v, want the acorn", inv.Slots)
			}
			if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 0 {
				t.Fatalf("logged %d %s events for a pickup that needed no walk: %+v",
					len(assigned), game.EvPathAssigned, assigned)
			}
			alice.expectSilence()
		})
	}
}

// TestPickupWithinRangeStillWalksToTheItem pins the carve-out that PROTOCOL.md
// deleted. PickupRange decides when the tick loop hands the item over; it is
// never a distance at which the server declines to walk the player.
//
// The walk is a quarter of a world unit and ends the same tick it started, which
// is the point: the path exists, it is broadcast, and no rule anywhere compares
// the distance against PickupRange before assigning it.
func TestPickupWithinRangeStillWalksToTheItem(t *testing.T) {
	const near = game.PickupRange / 2
	h := newHarness(t, acornAt(near, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	alice.pickup(item)

	assigned := alice.path()
	if len(assigned.Points) != 2 {
		t.Fatalf("path has %d points, want a start and the item: %+v", len(assigned.Points), assigned.Points)
	}
	if assigned.Points[0] != mnet.Pt(0, 0) || assigned.Points[1] != mnet.Pt(near, 0) {
		t.Fatalf("path is %v, want (0, 0) to the item at (%v, 0)", assigned.Points, near)
	}
	if inv := alice.awaitInventory(); len(inv.Slots) != 1 {
		t.Fatalf("inventory holds %+v, want the acorn", inv.Slots)
	}
}

// TestPickupOfAnItemThatIsNotThereIsAnsweredOnce covers a fabricated id and a
// stale one with the same assertion, because the server answers them
// identically on purpose: telling a client which ids exist is telling it about
// items it cannot see.
func TestPickupOfAnItemThatIsNotThereIsAnsweredOnce(t *testing.T) {
	h := newHarness(t, acornAt(game.PickupRange/2, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	real := welcome.Items[0].ID

	// Take the real one first, so the id below is stale rather than invented.
	alice.pickup(real)
	alice.awaitInventory()

	for _, item := range []mnet.ItemID{real, 9999} {
		alice.pickup(item)

		refusal := alice.errorFrame()
		if refusal.Re != mnet.MsgPickup {
			t.Fatalf("item %d: error attributed to %q, want %q", item, refusal.Re, mnet.MsgPickup)
		}
		if refusal.Msg == "" {
			t.Fatalf("item %d: error carries no message for a human to read", item)
		}
		// One error and nothing else: no path, no despawn, no inventory.
		alice.expectSilence()
	}

	rejected := h.awaitEvents(game.EvPickupRejected, 2)
	for _, ev := range rejected {
		if got := ev["reason"]; got != string(mnet.ReasonUnknownItem) {
			t.Fatalf("%s reports reason %v, want %q", game.EvPickupRejected, got, mnet.ReasonUnknownItem)
		}
	}
	// A pickup refusal is not filed under move_to's name.
	if moved := h.eventsNamed(game.EvMoveToRejected); len(moved) != 0 {
		t.Fatalf("a refused pickup was logged as %s: %+v", game.EvMoveToRejected, moved)
	}
}

// TestASecondPickupReplacesTheFirst. A player has at most one pending pickup,
// so the second click wins and the first item is left alone.
func TestASecondPickupReplacesTheFirst(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0), acornAt(-game.PickupRange/2, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	far, near := welcome.Items[0].ID, welcome.Items[1].ID

	alice.pickup(far)
	alice.path()

	alice.pickup(near)
	if inv := alice.awaitInventory(); len(inv.Slots) != 1 {
		t.Fatalf("inventory holds %+v, want the near acorn", inv.Slots)
	}

	// The far item is untouched: the walk towards it was abandoned, not
	// completed. Nothing further arrives about it.
	alice.expectSilence()

	bob := h.dial("bob")
	items := bob.welcome().Items
	if len(items) != 1 || items[0].ID != far {
		t.Fatalf("the world holds %+v, want only the far item %d", items, far)
	}
}

// TestAPickupWhileWalkingAwayFromANearItemStillTakesIt is the property the
// deleted carve-out violated, and the reason PROTOCOL.md deleted it rather than
// adding a second rule underneath it.
//
// The old clause said a player already inside PickupRange is assigned no path.
// For a player standing still that is right. For a player already walking it is
// broken: the walk they were on is never replaced, it carries them out of range
// on the next tick, and the pending pickup then never resolves for the rest of
// the session. A pickup is now a move_to at the item's position with no distance
// carve-out at all, so what she gets is an ordinary walk back to it.
func TestAPickupWhileWalkingAwayFromANearItemStillTakesIt(t *testing.T) {
	// The item sits a fraction of PickupRange from the staging point, so she is
	// well inside the range that used to suppress her path, and stays inside it
	// even if a tick slips in between the two intents below.
	const staging, near = 1.0, 1.05
	h := newHarness(t, acornAt(near, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	// Walk to the staging point first. Arriving both puts her next to the item
	// and marks a tick boundary, so the two intents below land in one tick.
	alice.moveTo(staging, 0)
	alice.path()
	h.awaitEvents(game.EvArrived, 1)

	// Away from the item, at right angles to it, so that a tick slipping in
	// costs her less of PickupRange than walking straight away would.
	alice.moveTo(staging, 20)
	alice.path()

	alice.pickup(item)

	// An ordinary two-point walk back to the item: not a halt, and not nothing.
	back := alice.path()
	if len(back.Points) != 2 {
		t.Fatalf("the pickup assigned %+v, want a two-point walk back to the item", back.Points)
	}
	if back.Points[1] != mnet.Pt(near, 0) {
		t.Fatalf("the walk ends at %v, want the item at (%v, 0)", back.Points[1], near)
	}
	if d := math.Hypot(back.Points[0].X()-near, back.Points[0].Z()); d > game.PickupRange {
		t.Fatalf("she was %v from the item when she asked, want inside PickupRange (%v): a tick fell "+
			"between the two intents, so this run proved nothing about the near case", d, game.PickupRange)
	}

	// And the property the whole rule exists for: she ends up holding it.
	if inv := alice.awaitInventory(); len(inv.Slots) != 1 || inv.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("she holds %+v, want the acorn she asked for", inv.Slots)
	}
	alice.expectSilence()
}

// TestMoveToCancelsAPendingPickup. Clicking the ground says you wanted
// something else, so walking over the item afterwards takes nothing.
func TestMoveToCancelsAPendingPickup(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	alice.pickup(item)
	alice.path()

	// Straight through the item and out the far side, so walking over it is
	// what the assertion is about rather than stopping short of it.
	alice.moveTo(farItem+1, 0)
	alice.path()

	h.awaitEvents(game.EvArrived, 1)
	alice.expectSilence()

	bob := h.dial("bob")
	if items := bob.welcome().Items; len(items) != 1 || items[0].ID != item {
		t.Fatalf("the world holds %+v, want the acorn still lying there", items)
	}
}

// TestTwoClientsRacingForOneItemLeaveExactlyOneHolder is the unit's reason to
// exist: two real clients, one item, and a server that hands it to exactly one
// of them.
//
// The winner is asserted by name rather than as a disjunction. Join order
// decides a contest, alice joined first, so alice wins; a test that accepted
// either answer would pass against a server that picked at random, which is the
// one thing this milestone must rule out.
func TestTwoClientsRacingForOneItemLeaveExactlyOneHolder(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	item := aliceWelcome.Items[0].ID

	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn() // bob joining

	// Both start from the spawn point, so both are the same distance from the
	// item and neither has a head start.
	alice.pickup(item)
	bob.pickup(item)
	h.awaitEvents(game.EvPathAssigned, 2)

	// Exactly one pickup resolves, and it resolves for alice.
	resolved := h.awaitEvents(game.EvPickupResolved, 1)
	if got := resolved[0]["player"]; got != float64(aliceWelcome.You) {
		t.Fatalf("item %d went to player %v, want alice (%d): join order decides a contest",
			item, got, aliceWelcome.You)
	}
	lost := h.awaitEvents(game.EvPickupLost, 1)
	if got := lost[0]["player"]; got != float64(bobWelcome.You) {
		t.Fatalf("%s names player %v, want bob (%d)", game.EvPickupLost, got, bobWelcome.You)
	}

	// The winner holds it.
	inv := alice.awaitInventory()
	if len(inv.Slots) != 1 || inv.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("alice holds %+v, want one acorn", inv.Slots)
	}

	// The loser holds nothing, and is told so by never being sent an
	// inventory: one is sent when and only when a player's inventory changes.
	for _, f := range bob.collect(silenceWindow) {
		if f.Inventory != nil {
			t.Fatalf("bob's inventory was restated for a pickup he lost: %s", f.raw)
		}
	}
	carol := h.dial("carol")
	if items := carol.welcome().Items; len(items) != 0 {
		t.Fatalf("a client joining after the contest sees %+v, want an empty world", items)
	}

	// And exactly one resolution happened in total, not two racing writes that
	// happened to agree.
	if got := h.eventsNamed(game.EvPickupResolved); len(got) != 1 {
		t.Fatalf("%d pickups resolved for one item, want 1: %+v", len(got), got)
	}
}

// TestTheLoserIsHaltedAndToldWhy is the other side of the contest. Walking on
// to an empty patch of ground would be the server lying about the world, so the
// loser gets a one-element halt path, broadcast like any other path, and an
// error naming pickup.
func TestTheLoserIsHaltedAndToldWhy(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	item := alice.welcome().Items[0].ID

	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn()

	alice.pickup(item)
	bob.pickup(item)

	// The halt reaches alice too, who is not the loser: a path broadcasts to
	// everyone, and an observer has to be able to draw bob stopping.
	halt := alice.awaitHaltPath(bobWelcome.You)
	if len(halt.Points) != 1 {
		t.Fatalf("halt path has %d points, want 1: %+v", len(halt.Points), halt.Points)
	}
	if halt.Points[0].X() <= 0 || halt.Points[0].X() > farItem {
		t.Fatalf("bob halted at %v, want somewhere between the spawn point and the item", halt.Points[0])
	}

	refusal := bob.awaitError()
	if refusal.Re != mnet.MsgPickup {
		t.Fatalf("bob's error is attributed to %q, want %q", refusal.Re, mnet.MsgPickup)
	}

	// Halted means halted: nothing moves him afterwards.
	bob.drain()
	bob.expectSilence()
}

// TestBothRacersArriveOnTheSameTick is what makes the contest a contest rather
// than a sequence. Two players from one spawn point, walking at one speed to
// one item, are equidistant, so same-tick arrival is the ordinary case.
//
// The two intents have to be processed inside one tick for that to hold, so the
// test starts them just after a tick boundary rather than hoping. The
// boundary is observed through the log: an arrived event is written during
// step, so seeing one means a tick has just run.
func TestBothRacersArriveOnTheSameTick(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	item := aliceWelcome.Items[0].ID

	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn()

	// A short walk to one shared point, which both leaves them co-located and
	// gives the test a tick boundary to start from.
	const staging = 1.0
	alice.moveTo(staging, 0)
	bob.moveTo(staging, 0)
	h.awaitEvents(game.EvArrived, 2)
	alice.drain()
	bob.drain()

	alice.pickup(item)
	bob.pickup(item)

	paths := h.awaitEvents(game.EvPathAssigned, 4) // two staging walks, two pickups
	aliceStart, bobStart := paths[2]["start_tick"], paths[3]["start_tick"]
	if aliceStart != bobStart {
		t.Fatalf("the two pickups were assigned paths at ticks %v and %v, so a tick boundary fell between "+
			"them and the walks cannot end together; the race is a sequence", aliceStart, bobStart)
	}

	// One resolution and one loss, in the same tick: bob finds the item gone in
	// the same pass that gave it to alice.
	won := h.awaitEvents(game.EvPickupResolved, 1)
	lost := h.awaitEvents(game.EvPickupLost, 1)
	if won[0]["t"] != lost[0]["t"] {
		t.Fatalf("alice took the item on tick %v and bob learned it was gone on tick %v; "+
			"equidistant walkers must resolve in one pass", won[0]["t"], lost[0]["t"])
	}
	if got := won[0]["player"]; got != float64(aliceWelcome.You) {
		t.Fatalf("the same-tick winner is %v, want alice (%d)", got, aliceWelcome.You)
	}
	if got := lost[0]["player"]; got != float64(bobWelcome.You) {
		t.Fatalf("the same-tick loser is %v, want bob (%d)", got, bobWelcome.You)
	}
}

// TestAFullInventoryLeavesTheItemOnTheGround. The player stops where they are,
// the item does not move, and no halt path is sent, because arriving is what
// ended the walk.
func TestAFullInventoryLeavesTheItemOnTheGround(t *testing.T) {
	if testing.Short() {
		t.Skip("fills 28 slots one tick at a time")
	}

	seeds := make([]seed, 0, game.InventorySize+1)
	for range game.InventorySize {
		// On the spawn point, so each take costs one tick rather than a walk.
		seeds = append(seeds, acornAt(0, 0))
	}
	seeds = append(seeds, acornAt(game.PickupRange/2, 0))
	h := newHarness(t, seeds...)

	alice := h.dial("alice")
	welcome := alice.welcome()

	// One pickup at a time: a second pickup replaces the first, so filling the
	// inventory means waiting for each take before asking for the next.
	for i := range game.InventorySize {
		alice.pickup(welcome.Items[i].ID)
		if got := len(alice.awaitInventory().Slots); got != i+1 {
			t.Fatalf("after %d pickups the inventory holds %d items, want %d", i+1, got, i+1)
		}
	}

	overflow := welcome.Items[game.InventorySize].ID
	alice.pickup(overflow)

	refusal := alice.awaitError()
	if refusal.Re != mnet.MsgPickup {
		t.Fatalf("error attributed to %q, want %q", refusal.Re, mnet.MsgPickup)
	}
	if !strings.Contains(refusal.Msg, "full") {
		t.Fatalf("error says %q, want it to mention a full inventory", refusal.Msg)
	}

	// No halt path and no despawn: only the error.
	alice.expectSilence()

	bob := h.dial("bob")
	items := bob.welcome().Items
	if len(items) != 1 || items[0].ID != overflow {
		t.Fatalf("the world holds %+v, want the refused item %d still lying there", items, overflow)
	}
	if got := h.eventsNamed(game.EvPickupNoRoom); len(got) != 1 {
		t.Fatalf("logged %d %s events, want 1", len(got), game.EvPickupNoRoom)
	}
}

// TestItemDespawnReachesThePlayerWhoCausedIt is path's broadcast rule, not
// spawn's. A picker who did not hear the despawn would have to remove the body
// on its own authority, which is a client deciding what the world contains.
func TestItemDespawnReachesThePlayerWhoCausedIt(t *testing.T) {
	h := newHarness(t, acornAt(game.PickupRange/2, 0))

	alice := h.dial("alice")
	item := alice.welcome().Items[0].ID

	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.pickup(item)

	// Both of them, and the taker is not excluded.
	if got := alice.awaitItemDespawn(item); got.ID != item {
		t.Fatalf("the taker was told about item %d, want %d", got.ID, item)
	}
	if got := bob.awaitItemDespawn(item); got.ID != item {
		t.Fatalf("the observer was told about item %d, want %d", got.ID, item)
	}
}

// TestTheEventLogRecordsEveryItemStateChange is the acceptance the log has to
// meet on its own: an item entering the world, an intent arriving, a resolution
// and a refusal each have a name of their own, and the fields two of them share
// are spelled the same way.
func TestTheEventLogRecordsEveryItemStateChange(t *testing.T) {
	h := newHarness(t, acornAt(game.PickupRange/2, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	alice.pickup(item)
	alice.awaitInventory()
	alice.pickup(item) // now stale
	alice.errorFrame()

	spawned := h.awaitEvents(game.EvItemSpawned, 1)
	intents := h.awaitEvents(game.EvPickup, 2)
	resolved := h.awaitEvents(game.EvPickupResolved, 1)
	refused := h.awaitEvents(game.EvPickupRejected, 1)

	if got := spawned[0]["item"]; got != float64(item) {
		t.Errorf("%s names item %v, want %d", game.EvItemSpawned, got, item)
	}
	// The shared helper is what keeps these spellings identical across events.
	for _, ev := range []map[string]any{intents[0], resolved[0]} {
		if got := ev["item"]; got != float64(item) {
			t.Errorf("%v names item %v, want %d", ev["ev"], got, item)
		}
		if got := ev["player"]; got != float64(welcome.You) {
			t.Errorf("%v names player %v, want %d", ev["ev"], got, welcome.You)
		}
	}
	if got := resolved[0]["slot"]; got != float64(0) {
		t.Errorf("%s reports slot %v, want 0", game.EvPickupResolved, got)
	}
	if got := resolved[0]["kind"]; got != game.KindAcorn {
		t.Errorf("%s reports kind %v, want %q", game.EvPickupResolved, got, game.KindAcorn)
	}
	if got := refused[0]["re"]; got != mnet.MsgPickup {
		t.Errorf("%s is attributed to %v, want %q", game.EvPickupRejected, got, mnet.MsgPickup)
	}

	// The resolution is one tick, so the take and the despawn share it.
	if spawned[0]["t"] == resolved[0]["t"] {
		t.Errorf("the item was seeded and taken on the same tick %v, so this test proved nothing about timing",
			resolved[0]["t"])
	}
}

// TestAMalformedPickupIsRefusedWithoutClosing keeps pickup on the same footing
// as move_to: a broken body is a broken frame, not a broken client.
func TestAMalformedPickupIsRefusedWithoutClosing(t *testing.T) {
	h := newHarness(t, acornAt(game.PickupRange/2, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()

	cases := []struct {
		frame string
		want  mnet.RejectReason
	}{
		{`{"pickup":{}}`, mnet.ReasonMissingField},
		{`{"pickup":{"item":"acorn"}}`, mnet.ReasonMalformedJSON},
		{`{"pickup":{"item":1.5}}`, mnet.ReasonMalformedJSON},
	}
	for _, tc := range cases {
		alice.sendRaw(tc.frame)
		if refusal := alice.errorFrame(); refusal.Re != mnet.MsgPickup {
			t.Fatalf("%s: error attributed to %q, want %q", tc.frame, refusal.Re, mnet.MsgPickup)
		}
	}

	rejected := h.awaitEvents(game.EvPickupRejected, len(cases))
	for i, tc := range cases {
		if got := rejected[i]["reason"]; got != string(tc.want) {
			t.Fatalf("%s rejected with %v, want %q", tc.frame, got, tc.want)
		}
	}

	// Still a working client, and still able to pick the item up.
	alice.pickup(welcome.Items[0].ID)
	if inv := alice.awaitInventory(); len(inv.Slots) != 1 {
		t.Fatalf("after three bad frames alice holds %+v, want the acorn", inv.Slots)
	}
}

// TestPickupSurvivesTheClientLeavingMidWalk. A disconnect while a pickup is
// pending must not leave the world holding a pointer to a departed player, and
// the item must stay where it is.
func TestPickupSurvivesTheClientLeavingMidWalk(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	item := alice.welcome().Items[0].ID
	alice.pickup(item)
	alice.path()
	alice.close()
	h.awaitEvents(game.EvDisconnected, 1)

	// Long enough that the abandoned walk would have arrived.
	walk := farItem / game.WalkSpeed * float64(time.Second)
	time.Sleep(time.Duration(walk) + game.TickDuration)

	bob := h.dial("bob")
	if items := bob.welcome().Items; len(items) != 1 || items[0].ID != item {
		t.Fatalf("the world holds %+v, want the acorn the departed client was walking to", items)
	}
}
