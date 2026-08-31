package game_test

import (
	"math"
	"testing"

	"github.com/devarminas/marque/server/internal/game"
)

const epsilon = 1e-9

func TestStraightLineStartsWhereTheWalkerIs(t *testing.T) {
	t.Parallel()

	from := game.Point{X: 1.5, Z: -2.5}
	to := game.Point{X: 10, Z: 4}
	got := game.StraightLine(from, to)

	if len(got) != 2 {
		t.Fatalf("StraightLine returned %d points, want 2: %v", len(got), got)
	}
	if got[0] != from {
		t.Fatalf("points[0] = %v, want the walker's own position %v", got[0], from)
	}
	if got[1] != to {
		t.Fatalf("points[1] = %v, want the destination %v", got[1], to)
	}
}

func TestAdvancePartway(t *testing.T) {
	t.Parallel()

	pos, remaining := game.Advance(game.Point{}, []game.Point{{X: 10}}, 2.5)
	if math.Abs(pos.X-2.5) > epsilon || math.Abs(pos.Z) > epsilon {
		t.Fatalf("position %v, want {2.5 0}", pos)
	}
	if len(remaining) != 1 {
		t.Fatalf("remaining %v, want the waypoint still ahead", remaining)
	}
}

func TestAdvanceReachesWaypointExactly(t *testing.T) {
	t.Parallel()

	pos, remaining := game.Advance(game.Point{}, []game.Point{{X: 3, Z: 4}}, 5)
	if pos != (game.Point{X: 3, Z: 4}) {
		t.Fatalf("position %v, want the waypoint itself {3 4}", pos)
	}
	if len(remaining) != 0 {
		t.Fatalf("remaining %v, want empty: the walk is over", remaining)
	}
}

func TestAdvanceCarriesLeftoverDistanceAroundCorners(t *testing.T) {
	t.Parallel()

	// Two segments of length 3 and 4. Ten units of travel overshoots both.
	pos, remaining := game.Advance(
		game.Point{},
		[]game.Point{{X: 3}, {X: 3, Z: 4}},
		10,
	)
	if pos != (game.Point{X: 3, Z: 4}) {
		t.Fatalf("position %v, want the final waypoint {3 4}", pos)
	}
	if len(remaining) != 0 {
		t.Fatalf("remaining %v, want empty", remaining)
	}
}

func TestAdvanceConsumesZeroLengthPath(t *testing.T) {
	t.Parallel()

	// Clicking where you already stand still yields a path, and that path must
	// finish rather than leave the player walking forever.
	pos, remaining := game.Advance(game.Point{X: 7}, []game.Point{{X: 7}}, 0.45)
	if pos != (game.Point{X: 7}) {
		t.Fatalf("position %v, want {7 0}", pos)
	}
	if len(remaining) != 0 {
		t.Fatalf("remaining %v, want empty", remaining)
	}
}

func TestAdvanceWithoutWaypointsStandsStill(t *testing.T) {
	t.Parallel()

	pos, remaining := game.Advance(game.Point{X: 1, Z: 2}, nil, 5)
	if pos != (game.Point{X: 1, Z: 2}) {
		t.Fatalf("position %v, want it unchanged", pos)
	}
	if len(remaining) != 0 {
		t.Fatalf("remaining %v, want empty", remaining)
	}
}

func TestAdvanceRejectsNegativeDistance(t *testing.T) {
	t.Parallel()

	defer func() {
		if recover() == nil {
			t.Fatal("Advance accepted a negative distance; movement along a path is monotonic")
		}
	}()
	game.Advance(game.Point{}, []game.Point{{X: 10}}, -1)
}

func TestTickConstantIsTheDecidedOne(t *testing.T) {
	t.Parallel()

	// The tick is settled at 150ms and revisitable exactly once, after M1. This
	// asserts the constant rather than the behaviour, so that changing it is a
	// deliberate act with a failing test attached.
	if game.TickDuration.Milliseconds() != 150 {
		t.Fatalf("TickDuration is %v, want 150ms", game.TickDuration)
	}
}
