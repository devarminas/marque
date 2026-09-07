package game

import (
	"sort"

	"github.com/devarminas/marque/server/internal/classdef"
)

const (
	ClassKitSeedOriginX  = 1.0
	ClassKitSeedOriginZ  = 2.0
	ClassKitSeedSpacingX = 3 * PickupRange
	ClassKitSeedSpacingZ = 4 * PickupRange
)

type ClassKitSeed struct {
	Kind string
	X, Z float64
}

func ClassKitSeeds(cat *classdef.Catalog) []ClassKitSeed {
	if cat == nil {
		return nil
	}
	setIDs := cat.SetIDs()
	sort.Strings(setIDs)

	seen := make(map[string]struct{})
	out := make([]ClassKitSeed, 0)
	for row, setID := range setIDs {
		s, ok := cat.GetSet(setID)
		if !ok {
			continue
		}
		kinds := setKindsInOrder(s)
		col := 0
		for _, kind := range kinds {
			if _, dup := seen[kind]; dup {
				continue
			}
			seen[kind] = struct{}{}
			out = append(out, ClassKitSeed{
				Kind: kind,
				X:    ClassKitSeedOriginX + float64(col)*ClassKitSeedSpacingX,
				Z:    ClassKitSeedOriginZ + float64(row)*ClassKitSeedSpacingZ,
			})
			col++
		}
	}
	return out
}

func setKindsInOrder(s classdef.Set) []string {
	slotKeys := make([]string, 0, len(s.Slots))
	for k := range s.Slots {
		slotKeys = append(slotKeys, k)
	}
	sort.Strings(slotKeys)
	out := make([]string, 0, len(s.Slots)+len(s.Tools))
	for _, slot := range slotKeys {
		out = append(out, s.Slots[slot])
	}
	toolKeys := make([]string, 0, len(s.Tools))
	for k := range s.Tools {
		toolKeys = append(toolKeys, k)
	}
	sort.Strings(toolKeys)
	out = append(out, toolKeys...)
	return out
}
