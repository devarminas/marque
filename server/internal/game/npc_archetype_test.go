package game

import (
	"testing"

	"github.com/devarminas/marque/server/internal/npcdef"
)

func TestSeedImpFailsClosedWithoutArchetype(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetNPCArchetypes(nil)
	err := pw.w.seedNPC(KindImp, FactionHostile, 5, 5, 50)
	if err == nil {
		t.Fatal("expected seed to fail without archetypes")
	}
}

func TestSeedImpReadsMaxHPFromArchetype(t *testing.T) {
	pw := newProbeWorld(t)
	cat, err := npcdef.Parse([]byte(`{"archetypes":[{
		"id":"imp","max_hp":80,"weapon_id":"imp_claw","threat":8,"leash":16,"wander":3,
		"skills":["fireball"],"idle_min_ticks":50,"idle_max_ticks":150,
		"str":10,"dex":10,"con":8,"int":10
	}]}`))
	if err != nil {
		t.Fatal(err)
	}
	pw.w.SetNPCArchetypes(cat)
	if err := pw.w.seedNPC(KindImp, FactionHostile, 5, 5, 1); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	if imp.maxHP != 80 || imp.hp != 80 {
		t.Fatalf("hp=%d/%d, want 80 from JSON", imp.hp, imp.maxHP)
	}
	if imp.weapon != "imp_claw" {
		t.Fatalf("weapon=%q", imp.weapon)
	}
	if imp.attrs.CON != 8 {
		t.Fatalf("CON=%d, want 8", imp.attrs.CON)
	}
}
