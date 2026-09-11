package game

import "fmt"

// Map identity strings. Client play-path selection (M14b) and server -map must
// use the same id; welcome restates it so a mismatched client can refuse.
const (
	MapVillage           = "village"
	MapArenaRingOfTrials = "arena_ring_of_trials"
)

// VillageHalfExtent is the starter-town playable half-extent (±square).
const VillageHalfExtent = 128.0

// WorldHalfExtent keeps the historical village default name used by tests and
// logs when no arena map is selected.
const WorldHalfExtent = VillageHalfExtent

// ArenaHalfExtent covers the Ring of Trials navmesh XZ AABB (max |axis| ≈ 82.9)
// with a small margin. Village ±128 still contains the mesh; arena mode tightens
// the server clamp to the playable extent.
const ArenaHalfExtent = 84.0

// ArenaFloorY is the authored center-floor height of arena_ring_of_trials
// (navmesh / GLB). Flat until M14d/e wire per-triangle HeightAt.
const ArenaFloorY = 0.4

// MapConfig is the server-side active map: identity, bounds, and join spawn.
type MapConfig struct {
	ID         string
	HalfExtent float64
	SpawnX     float64
	SpawnY     float64
	SpawnZ     float64
	GroundY    float64
}

// VillageMap is the default starter-town map.
var VillageMap = MapConfig{
	ID:         MapVillage,
	HalfExtent: VillageHalfExtent,
	SpawnX:     0,
	SpawnY:     0,
	SpawnZ:     0,
	GroundY:    0,
}

// ArenaRingOfTrialsMap places join/respawn on the arena floor with arena bounds.
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
