package game

import (
	"testing"

	"github.com/devarminas/marque/server/internal/classdef"
)

type classProbe struct {
	*probeWorld
}

func newClassProbe(t *testing.T) *classProbe {
	t.Helper()
	pw := newProbeWorld(t)
	pw.w.joinKit = DefaultJoinKit
	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatalf("load shared class tables: %v", err)
	}
	pw.w.SetClasses(classes)
	return &classProbe{probeWorld: pw}
}

func (pw *classProbe) joinBare() *player {
	pw.t.Helper()
	kit := pw.w.joinKit
	pw.w.joinKit = nil
	pw.dial("")
	pw.w.joinKit = kit
	return pw.w.order[len(pw.w.order)-1]
}

func (pw *classProbe) equipClass(p *player, id string) *player {
	pw.t.Helper()
	cl, ok := pw.w.classes.GetClass(id)
	if !ok {
		pw.t.Fatalf("missing class %q", id)
	}
	seen := make(map[string]struct{})
	kinds := make([]string, 0, len(cl.Requires))
	for _, kind := range cl.Requires {
		if _, dup := seen[kind]; dup {
			continue
		}
		seen[kind] = struct{}{}
		kinds = append(kinds, kind)
	}
	for _, kind := range kinds {
		slot, err := pw.w.items.SpawnInventoryItem(p.id, kind)
		if err != nil {
			pw.t.Fatalf("seed %q: %v", kind, err)
		}
		if _, err := pw.w.items.EquipInventorySlot(p.id, slot.Index); err != nil {
			pw.t.Fatalf("equip %q from bag %d: %v", kind, slot.Index, err)
		}
	}
	res := classdef.ClassOf(pw.w.wornKinds(p), pw.w.classes)
	if res.Class == nil || res.Class.ID != id {
		pw.t.Fatalf("after equip, class=%v, want %q", res.Class, id)
	}
	return p
}

func (pw *classProbe) joinWithClass(id string) *player {
	pw.t.Helper()
	return pw.equipClass(pw.joinBare(), id)
}

func (pw *classProbe) seedHostile() *npc {
	pw.t.Helper()
	if err := pw.w.SeedPracticeDummies(); err != nil {
		pw.t.Fatalf("seed dummies: %v", err)
	}
	return pw.w.npcByFaction(FactionHostile)
}

func (pw *classProbe) seedFriendly() *npc {
	pw.t.Helper()
	if err := pw.w.SeedPracticeDummies(); err != nil {
		pw.t.Fatalf("seed dummies: %v", err)
	}
	return pw.w.npcByFaction(FactionFriendly)
}
