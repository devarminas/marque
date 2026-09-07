package net_test


import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const farItem = 10.0

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
	if welcome.You != 1 {
		t.Fatalf("the first player is %d, want 1: item ids must not consume player ids", welcome.You)
	}

	inv := alice.inventory()
	if inv.Size != game.InventorySize {
		t.Fatalf("inventory size is %d, want %d", inv.Size, game.InventorySize)
	}
	if len(inv.Slots) != 0 {
		t.Fatalf("a fresh player starts holding %+v, want nothing", inv.Slots)
	}

	if worn := alice.equipment(); len(worn.Slots) != 0 {
		t.Fatalf("a fresh player starts wearing %+v, want nothing", worn.Slots)
	}

	if got := alice.classFrame(); got.Class != "" {
		t.Fatalf("a fresh player's class frame reports %q, want none", got.Class)
	}
	if skills := alice.skillsFrame(); len(skills.Skills) == 0 {
		t.Fatal("a fresh player's skills frame lists no skills")
	}

	alice.expectSilence()
}

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

func TestPickupWalksThenTakes(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	alice.pickup(item)

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

func TestPickupOfAnItemThatIsNotThereIsAnsweredOnce(t *testing.T) {
	h := newHarness(t, acornAt(game.PickupRange/2, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	real := welcome.Items[0].ID

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
		alice.expectSilence()
	}

	rejected := h.awaitEvents(game.EvPickupRejected, 2)
	for _, ev := range rejected {
		if got := ev["reason"]; got != string(mnet.ReasonUnknownItem) {
			t.Fatalf("%s reports reason %v, want %q", game.EvPickupRejected, got, mnet.ReasonUnknownItem)
		}
	}
	if moved := h.eventsNamed(game.EvMoveToRejected); len(moved) != 0 {
		t.Fatalf("a refused pickup was logged as %s: %+v", game.EvMoveToRejected, moved)
	}
}

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

	alice.expectSilence()

	bob := h.dial("bob")
	items := bob.welcome().Items
	if len(items) != 1 || items[0].ID != far {
		t.Fatalf("the world holds %+v, want only the far item %d", items, far)
	}
}

func TestAPickupWhileWalkingAwayFromANearItemStillTakesIt(t *testing.T) {
	const staging, near = 1.0, 1.05
	h := newHarness(t, acornAt(near, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	alice.moveTo(staging, 0)
	alice.path()
	h.awaitEvents(game.EvArrived, 1)

	alice.moveTo(staging, 20)
	alice.path()

	alice.pickup(item)

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

	if inv := alice.awaitInventory(); len(inv.Slots) != 1 || inv.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("she holds %+v, want the acorn she asked for", inv.Slots)
	}
	alice.expectSilence()
}

func TestMoveToCancelsAPendingPickup(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	alice.pickup(item)
	alice.path()

	alice.moveTo(farItem+1, 0)
	alice.path()

	h.awaitEvents(game.EvArrived, 1)
	alice.expectSilence()

	bob := h.dial("bob")
	if items := bob.welcome().Items; len(items) != 1 || items[0].ID != item {
		t.Fatalf("the world holds %+v, want the acorn still lying there", items)
	}
}

func TestTwoClientsRacingForOneItemLeaveExactlyOneHolder(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	item := aliceWelcome.Items[0].ID

	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn()

	alice.pickup(item)
	bob.pickup(item)
	h.awaitEvents(game.EvPathAssigned, 2)

	resolved := h.awaitEvents(game.EvPickupResolved, 1)
	if got := resolved[0]["player"]; got != float64(aliceWelcome.You) {
		t.Fatalf("item %d went to player %v, want alice (%d): join order decides a contest",
			item, got, aliceWelcome.You)
	}
	lost := h.awaitEvents(game.EvPickupLost, 1)
	if got := lost[0]["player"]; got != float64(bobWelcome.You) {
		t.Fatalf("%s names player %v, want bob (%d)", game.EvPickupLost, got, bobWelcome.You)
	}

	inv := alice.awaitInventory()
	if len(inv.Slots) != 1 || inv.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("alice holds %+v, want one acorn", inv.Slots)
	}

	for _, f := range bob.collect(silenceWindow) {
		if f.Inventory != nil {
			t.Fatalf("bob's inventory was restated for a pickup he lost: %s", f.raw)
		}
	}
	carol := h.dial("carol")
	if items := carol.welcome().Items; len(items) != 0 {
		t.Fatalf("a client joining after the contest sees %+v, want an empty world", items)
	}

	if got := h.eventsNamed(game.EvPickupResolved); len(got) != 1 {
		t.Fatalf("%d pickups resolved for one item, want 1: %+v", len(got), got)
	}
}

func TestTheLoserIsHaltedAndToldWhy(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	item := alice.welcome().Items[0].ID

	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn()

	alice.pickup(item)
	bob.pickup(item)

	halt := alice.awaitHaltPath(bobWelcome.You)
	if len(halt.Points) != 1 {
		t.Fatalf("halt path has %d points, want 1: %+v", len(halt.Points), halt.Points)
	}
	carol := h.dial("carol")
	bobNow := positionOf(t, carol.welcomeFrame(), bobWelcome.You)
	if halt.Points[0].X() != bobNow.X || halt.Points[0].Z() != bobNow.Z {
		t.Fatalf("bob was halted at %v, but the server puts bob at (%v, %v): a halt anywhere other "+
			"than the player's own position teleports them", halt.Points[0], bobNow.X, bobNow.Z)
	}
	if bobNow.X == farItem && bobNow.Z == 0 {
		t.Fatalf("bob halted on the item's own square (%v, %v), so the assertion above could not "+
			"have distinguished the two; move the seed", bobNow.X, bobNow.Z)
	}

	refusal := bob.awaitError()
	if refusal.Re != mnet.MsgPickup {
		t.Fatalf("bob's error is attributed to %q, want %q", refusal.Re, mnet.MsgPickup)
	}

	bob.drain()
	bob.expectSilence()
}

func TestBothRacersArriveOnTheSameTick(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	item := aliceWelcome.Items[0].ID

	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	alice.spawn()

	const staging = 1.0
	alice.moveTo(staging, 0)
	bob.moveTo(staging, 0)
	h.awaitEvents(game.EvArrived, 2)
	alice.drain()
	bob.drain()

	alice.pickup(item)
	bob.pickup(item)

	paths := h.awaitEvents(game.EvPathAssigned, 4)
	aliceStart, bobStart := paths[2]["start_tick"], paths[3]["start_tick"]
	if aliceStart != bobStart {
		t.Fatalf("the two pickups were assigned paths at ticks %v and %v, so a tick boundary fell between "+
			"them and the walks cannot end together; the race is a sequence", aliceStart, bobStart)
	}

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

func TestAFullInventoryLeavesTheItemOnTheGround(t *testing.T) {
	if testing.Short() {
		t.Skip("fills 28 slots one tick at a time")
	}

	seeds := make([]seed, 0, game.InventorySize+1)
	for range game.InventorySize {
		seeds = append(seeds, acornAt(0, 0))
	}
	seeds = append(seeds, acornAt(game.PickupRange/2, 0))
	h := newHarness(t, seeds...)

	alice := h.dial("alice")
	welcome := alice.welcome()

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

func TestItemDespawnReachesThePlayerWhoCausedIt(t *testing.T) {
	h := newHarness(t, acornAt(game.PickupRange/2, 0))

	alice := h.dial("alice")
	item := alice.welcome().Items[0].ID

	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.pickup(item)

	if got := alice.awaitItemDespawn(item); got.ID != item {
		t.Fatalf("the taker was told about item %d, want %d", got.ID, item)
	}
	if got := bob.awaitItemDespawn(item); got.ID != item {
		t.Fatalf("the observer was told about item %d, want %d", got.ID, item)
	}
}

func TestTheEventLogRecordsEveryItemStateChange(t *testing.T) {
	h := newHarness(t, acornAt(game.PickupRange/2, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	alice.pickup(item)
	alice.awaitInventory()
	alice.pickup(item)
	alice.errorFrame()

	spawned := h.awaitEvents(game.EvItemSpawned, 1)
	intents := h.awaitEvents(game.EvPickup, 2)
	resolved := h.awaitEvents(game.EvPickupResolved, 1)
	refused := h.awaitEvents(game.EvPickupRejected, 1)

	if got := spawned[0]["item"]; got != float64(item) {
		t.Errorf("%s names item %v, want %d", game.EvItemSpawned, got, item)
	}
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

	if spawned[0]["t"] == resolved[0]["t"] {
		t.Errorf("the item was seeded and taken on the same tick %v, so this test proved nothing about timing",
			resolved[0]["t"])
	}
}

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

	alice.pickup(welcome.Items[0].ID)
	if inv := alice.awaitInventory(); len(inv.Slots) != 1 {
		t.Fatalf("after three bad frames alice holds %+v, want the acorn", inv.Slots)
	}
}

func TestPickupSurvivesTheClientLeavingMidWalk(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	item := alice.welcome().Items[0].ID
	alice.pickup(item)
	alice.path()
	alice.close()
	h.awaitEvents(game.EvDisconnected, 1)

	walk := farItem / game.WalkSpeed * float64(time.Second)
	time.Sleep(time.Duration(walk) + game.TickDuration)

	bob := h.dial("bob")
	if items := bob.welcome().Items; len(items) != 1 || items[0].ID != item {
		t.Fatalf("the world holds %+v, want the acorn the departed client was walking to", items)
	}
}
