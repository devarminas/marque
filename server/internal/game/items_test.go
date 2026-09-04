package game

// Seeding, which is the only way an item enters the world in M1a and the only
// piece of item handling that runs outside the world goroutine.

import (
	"math"
	"strings"
	"testing"
)

// TestSeedingAdmitsAnItemAndLogsIt covers the happy path and the log line the
// acceptance asks for: an item entering the world is visible in the NDJSON.
func TestSeedingAdmitsAnItemAndLogsIt(t *testing.T) {
	w, logs := newStepWorld(t)

	if err := w.SeedGroundItem(KindAcorn, 3, -2); err != nil {
		t.Fatalf("seeding a legal coordinate: %v", err)
	}

	items := w.items.GroundItems()
	if len(items) != 1 {
		t.Fatalf("the world holds %d items, want 1: %+v", len(items), items)
	}
	if items[0].Kind != KindAcorn || items[0].X != 3 || items[0].Z != -2 {
		t.Fatalf("seeded %+v, want an acorn at (3, -2)", items[0])
	}

	spawned := eventsNamed(t, logs, EvItemSpawned)
	if len(spawned) != 1 {
		t.Fatalf("logged %d %s events, want 1: %+v", len(spawned), EvItemSpawned, spawned)
	}
	if got := number(t, spawned[0], "item"); got != float64(items[0].ID) {
		t.Errorf("%s names item %v, want %d", EvItemSpawned, got, items[0].ID)
	}
	if got := spawned[0]["kind"]; got != KindAcorn {
		t.Errorf("%s names kind %v, want %q", EvItemSpawned, got, KindAcorn)
	}
}

// TestSeedingRefusesACoordinateTheWorldWouldRefuse holds seeds to exactly the
// rule a move_to destination is held to. A seed outside the world is a startup
// failure, never a silently clamped item: an item nobody can legally walk to is
// a bug that only shows up as a player who never arrives.
func TestSeedingRefusesACoordinateTheWorldWouldRefuse(t *testing.T) {
	cases := []struct {
		name string
		x, z float64
		want string
	}{
		{"east of the world", WorldHalfExtent + 0.001, 0, "out of bounds"},
		{"west of the world", -WorldHalfExtent - 1, 0, "out of bounds"},
		{"south of the world", 0, WorldHalfExtent * 2, "out of bounds"},
		{"a large finite float", 1e30, 0, "out of bounds"},
		{"not a number", math.NaN(), 0, "finite"},
		{"infinite", 0, math.Inf(1), "finite"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w, logs := newStepWorld(t)

			err := w.SeedGroundItem(KindAcorn, tc.x, tc.z)
			if err == nil {
				t.Fatalf("seeding (%v, %v) was accepted, want a startup failure", tc.x, tc.z)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error is %q, want it to mention %q", err, tc.want)
			}
			if items := w.items.GroundItems(); len(items) != 0 {
				t.Errorf("a refused seed still admitted %+v", items)
			}
			if spawned := eventsNamed(t, logs, EvItemSpawned); len(spawned) != 0 {
				t.Errorf("a refused seed logged %s: %+v", EvItemSpawned, spawned)
			}
		})
	}
}

// TestSeedsEnterInTheOrderTheyWereGiven is what lets a caller predict the ids
// it is about to be handed, which every test and every launch script relies on.
func TestSeedsEnterInTheOrderTheyWereGiven(t *testing.T) {
	w, _ := newStepWorld(t)

	for i := range 3 {
		if err := w.SeedGroundItem(KindAcorn, float64(i), 0); err != nil {
			t.Fatalf("seed %d: %v", i, err)
		}
	}

	items := w.items.GroundItems()
	for i, item := range items {
		if int(item.ID) != i+1 || item.X != float64(i) {
			t.Fatalf("item %d is %+v, want id %d at x=%d", i, item, i+1, i)
		}
	}
}

// TestSeedingRefusesAnItemWithNoKind. A kind is what the client renders, and an
// empty one would reach an M1c client as a body with no asset name at all.
func TestSeedingRefusesAnItemWithNoKind(t *testing.T) {
	w, _ := newStepWorld(t)

	if err := w.SeedGroundItem("", 0, 0); err == nil {
		t.Fatal("an item with no kind was accepted")
	}
}

func TestPickupRangeCoversTheSpotUnderfoot(t *testing.T) {
	if PickupRange < MinPathLength {
		t.Fatalf("PickupRange %v is below MinPathLength %v: a pickup underfoot assigns no path and never closes the gap", PickupRange, MinPathLength)
	}
}
