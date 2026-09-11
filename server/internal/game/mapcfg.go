package game

import "fmt"

const (
	MapVillage           = "village"
	MapArenaRingOfTrials = "arena_ring_of_trials"
)

const WorldHalfExtent = 128.0

// ArenaHalfExtent covers the Ring of Trials navmesh XZ AABB (max |axis| ≈ 82.9)
// with a small margin. Village ±128 still contains the mesh; arena mode tightens
// the server clamp to the playable extent.
const ArenaHalfExtent = 84.0

// ArenaFloorY is the authored center-floor height of arena_ring_of_trials
// (navmesh / GLB). Flat until M14d/e wire per-triangle HeightAt.
const ArenaFloorY = 0.4

type MapConfig struct {
	ID         string
	HalfExtent float64
	SpawnX     float64
	SpawnY     float64
	SpawnZ     float64
	GroundY    float64
}

var VillageMap = MapConfig{
	ID:         MapVillage,
	HalfExtent: WorldHalfExtent,
	SpawnX:     0,
	SpawnY:     0,
	SpawnZ:     0,
	GroundY:    0,
}

var ArenaRingOfTrialsMap = MapConfig{
	ID:         MapArenaRingOfTrials,
	HalfExtent: ArenaHalfExtent,
	SpawnX:     0,
	SpawnY:     ArenaFloorY,
	SpawnZ:     0,
	GroundY:    ArenaFloorY,
}

func LookupMap(id string) (MapConfig, error) {
	switch id {
	case "", MapVillage:
		return VillageMap, nil
	case MapArenaRingOfTrials:
		return ArenaRingOfTrialsMap, nil
	default:
		return MapConfig{}, fmt.Errorf("unknown map %q (want %q or %q)", id, MapVillage, MapArenaRingOfTrials)
	}
}
