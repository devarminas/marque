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

func TestStarterTownRocksAreOnRoad(t *testing.T) {
	if len(StarterTownRocks) < 1 {
		t.Fatalf("StarterTownRocks has %d entries, want at least 1", len(StarterTownRocks))
	}
	seen := map[Point]struct{}{}
	for _, p := range StarterTownTrees {
		seen[p] = struct{}{}
	}
	for _, p := range StarterTownRocks {
		if _, ok := seen[p]; ok {
			t.Fatalf("starter rock overlaps a tree at %+v", p)
		}
		seen[p] = struct{}{}
		if reason, detail := checkCoordinates(p.X, p.Z); reason != "" {
			t.Fatalf("starter rock %+v: %s (%s)", p, reason, detail)
		}
	}
	if _, ok := seen[Point{X: SeedRockX, Z: SeedRockZ}]; !ok {
		t.Fatalf("StarterTownRocks missing primary rock (%v,%v)", SeedRockX, SeedRockZ)
	}
}
