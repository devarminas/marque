package game

import (
	"math"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestArenaJoinSpawnsOnFloor(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetMap(ArenaRingOfTrialsMap)

	alice := pw.join()
	if pw.w.MapID() != MapArenaRingOfTrials {
		t.Fatalf("map=%q, want %q", pw.w.MapID(), MapArenaRingOfTrials)
	}
	if alice.pos.X != ArenaRingOfTrialsMap.SpawnX || alice.pos.Z != ArenaRingOfTrialsMap.SpawnZ {
		t.Fatalf("pos=%v, want arena spawn XZ", alice.pos)
	}
	if math.Abs(alice.y-ArenaFloorY) > GroundEpsilon {
		t.Fatalf("y=%v, want arena floor %v", alice.y, ArenaFloorY)
	}
	if !pw.w.grounded(alice) {
		t.Fatal("join left player airborne on arena floor")
	}
	pw.w.step()
	if math.Abs(alice.y-ArenaFloorY) > GroundEpsilon {
		t.Fatalf("after step y=%v, want stay on floor %v", alice.y, ArenaFloorY)
	}
}

func TestArenaBoundsMatchPlayableExtent(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetMap(ArenaRingOfTrialsMap)

	if got := pw.w.HalfExtent(); got != ArenaHalfExtent {
		t.Fatalf("HalfExtent=%v, want %v", got, ArenaHalfExtent)
	}
	if ArenaHalfExtent >= VillageHalfExtent {
		t.Fatalf("arena half extent %v should be tighter than village %v", ArenaHalfExtent, VillageHalfExtent)
	}

	alice := pw.join()
	alice.pos = Point{X: ArenaHalfExtent, Z: 0}
	alice.y = ArenaFloorY
	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 0)
	pw.w.step()
	if alice.pos.X != ArenaHalfExtent {
		t.Fatalf("x=%v, want clamped at arena half extent %v", alice.pos.X, ArenaHalfExtent)
	}

	reason, _ := pw.w.checkCoordinates(ArenaHalfExtent+0.001, 0)
	if reason != mnet.ReasonOutOfBounds {
		t.Fatalf("drop past arena bounds reason=%v, want out of bounds", reason)
	}
	reason, _ = pw.w.checkCoordinates(VillageHalfExtent-1, 0)
	if reason != mnet.ReasonOutOfBounds {
		t.Fatalf("village-legal but arena-illegal point accepted: reason=%v", reason)
	}
}

func TestArenaRespawnReturnsToFloor(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetMap(ArenaRingOfTrialsMap)
	alice := pw.join()
	alice.hp = 0
	alice.pos = Point{X: 10, Z: -8}
	alice.y = 3
	pw.w.respawnPlayer(alice, 1)
	if alice.pos.X != ArenaRingOfTrialsMap.SpawnX || alice.pos.Z != ArenaRingOfTrialsMap.SpawnZ {
		t.Fatalf("respawn pos=%v", alice.pos)
	}
	if math.Abs(alice.y-ArenaFloorY) > GroundEpsilon {
		t.Fatalf("respawn y=%v, want %v", alice.y, ArenaFloorY)
	}
}

func TestVillageMapRemainsDefault(t *testing.T) {
	pw := newProbeWorld(t)
	if pw.w.MapID() != MapVillage {
		t.Fatalf("default map=%q, want %q", pw.w.MapID(), MapVillage)
	}
	if pw.w.HalfExtent() != VillageHalfExtent {
		t.Fatalf("default half=%v, want %v", pw.w.HalfExtent(), VillageHalfExtent)
	}
	alice := pw.join()
	if alice.y != 0 {
		t.Fatalf("village spawn y=%v, want 0", alice.y)
	}
}

func TestLookupMapRejectsUnknown(t *testing.T) {
	if _, err := LookupMap("not_a_map"); err == nil {
		t.Fatal("expected error for unknown map")
	}
}
