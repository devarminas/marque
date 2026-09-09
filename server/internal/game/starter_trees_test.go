package game

import "testing"

func TestStarterTownTreesAreDistinctAndOnRoad(t *testing.T) {
	if len(StarterTownTrees) < 2 {
		t.Fatalf("StarterTownTrees has %d entries, want at least 2", len(StarterTownTrees))
	}
	seen := map[Point]struct{}{}
	for _, p := range StarterTownTrees {
		if _, ok := seen[p]; ok {
			t.Fatalf("duplicate starter tree at %+v", p)
		}
		seen[p] = struct{}{}
		if reason, detail := checkCoordinates(p.X, p.Z); reason != "" {
			t.Fatalf("starter tree %+v: %s (%s)", p, reason, detail)
		}
	}
	if _, ok := seen[Point{X: SeedTreeX, Z: SeedTreeZ}]; !ok {
		t.Fatalf("StarterTownTrees missing primary demo tree (%v,%v)", SeedTreeX, SeedTreeZ)
	}
}
