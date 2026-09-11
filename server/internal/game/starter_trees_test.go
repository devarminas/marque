package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

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
		if reason, detail := villageCheckCoordinates(p.X, p.Z); reason != "" {
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
		if reason, detail := villageCheckCoordinates(p.X, p.Z); reason != "" {
			t.Fatalf("starter rock %+v: %s (%s)", p, reason, detail)
		}
	}
	if _, ok := seen[Point{X: SeedRockX, Z: SeedRockZ}]; !ok {
		t.Fatalf("StarterTownRocks missing primary rock (%v,%v)", SeedRockX, SeedRockZ)
	}
}

func TestStarterTownSmeltersAreOnRoad(t *testing.T) {
	if len(StarterTownSmelters) < 1 {
		t.Fatalf("StarterTownSmelters has %d entries, want at least 1", len(StarterTownSmelters))
	}
	seen := map[Point]struct{}{}
	for _, p := range StarterTownTrees {
		seen[p] = struct{}{}
	}
	for _, p := range StarterTownRocks {
		seen[p] = struct{}{}
	}
	for _, p := range StarterTownSmelters {
		if _, ok := seen[p]; ok {
			t.Fatalf("starter smelter overlaps a node at %+v", p)
		}
		seen[p] = struct{}{}
		if reason, detail := villageCheckCoordinates(p.X, p.Z); reason != "" {
			t.Fatalf("starter smelter %+v: %s (%s)", p, reason, detail)
		}
	}
	if _, ok := seen[Point{X: SeedSmelterX, Z: SeedSmelterZ}]; !ok {
		t.Fatalf("StarterTownSmelters missing primary smelter (%v,%v)", SeedSmelterX, SeedSmelterZ)
	}
}

func villageCheckCoordinates(x, z float64) (mnet.RejectReason, string) {
	w := &World{mapCfg: VillageMap}
	return w.checkCoordinates(x, z)
}
