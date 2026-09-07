package game

import (
	"path/filepath"
	"runtime"
	"testing"

	"github.com/devarminas/marque/server/internal/classdef"
)

func sharedSetsPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(classdef.SetsRelPath))
}

func TestClassKitSeedsUniqueKindsAndPositions(t *testing.T) {
	cat, err := classdef.LoadSets(sharedSetsPath(t))
	if err != nil {
		t.Fatalf("LoadSets: %v", err)
	}

	seeds := ClassKitSeeds(cat)
	if len(seeds) == 0 {
		t.Fatal("expected class kit seeds from shared sets")
	}

	wearables, err := cat.Wearables()
	if err != nil {
		t.Fatalf("Wearables: %v", err)
	}
	if len(seeds) != len(wearables) {
		t.Fatalf("got %d seeds, want %d (one per wearable kind)", len(seeds), len(wearables))
	}

	seen := make(map[string]struct{}, len(seeds))
	positions := make(map[[2]float64]string, len(seeds))
	for _, s := range seeds {
		if s.Kind == "" {
			t.Fatal("empty kind in ClassKitSeeds")
		}
		if _, ok := wearables[s.Kind]; !ok {
			t.Fatalf("seed kind %q is not in Wearables", s.Kind)
		}
		if _, dup := seen[s.Kind]; dup {
			t.Fatalf("duplicate kind %q", s.Kind)
		}
		seen[s.Kind] = struct{}{}

		key := [2]float64{s.X, s.Z}
		if other, taken := positions[key]; taken {
			t.Fatalf("kinds %q and %q share position (%v,%v)", other, s.Kind, s.X, s.Z)
		}
		positions[key] = s.Kind
	}

	// Sorted set ids: archer, knight, lumberjack, mage, miner.
	// First kind of archer (leather_chest via sorted slot keys) at origin.
	if seeds[0].X != ClassKitSeedOriginX || seeds[0].Z != ClassKitSeedOriginZ {
		t.Fatalf("first seed at (%v,%v), want origin (%v,%v)",
			seeds[0].X, seeds[0].Z, ClassKitSeedOriginX, ClassKitSeedOriginZ)
	}
	if d := seeds[1].X - seeds[0].X; d != ClassKitSeedSpacingX {
		t.Fatalf("X spacing %v, want %v", d, ClassKitSeedSpacingX)
	}

	var knightRowZ float64
	foundKnight := false
	for _, s := range seeds {
		if s.Kind == KindSword {
			foundKnight = true
			knightRowZ = s.Z
			break
		}
	}
	if !foundKnight {
		t.Fatal("missing sword seed")
	}
	// knight is the second sorted set id (after archer), so Z = origin + 1*spacing.
	wantZ := ClassKitSeedOriginZ + ClassKitSeedSpacingZ
	if knightRowZ != wantZ {
		t.Fatalf("sword Z=%v, want knight row %v", knightRowZ, wantZ)
	}
}

func TestClassKitSeedsNilCatalog(t *testing.T) {
	if got := ClassKitSeeds(nil); got != nil {
		t.Fatalf("got %#v, want nil", got)
	}
}

func TestClassKitSeedsStableAcrossCalls(t *testing.T) {
	cat, err := classdef.LoadSets(sharedSetsPath(t))
	if err != nil {
		t.Fatalf("LoadSets: %v", err)
	}
	a := ClassKitSeeds(cat)
	b := ClassKitSeeds(cat)
	if len(a) != len(b) {
		t.Fatalf("lengths %d vs %d", len(a), len(b))
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("index %d: %#v vs %#v", i, a[i], b[i])
		}
	}
}
