package game

import (
	"testing"
)

func TestNPCCombatantInstantHealSelf(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	if err := pw.w.seedNPC(KindImp, FactionHostile, 5, 5, ImpMaxHP); err != nil {
		t.Fatalf("seed imp: %v", err)
	}
	imp := pw.w.npcByKind(KindImp)
	imp.hp = 10

	if rej := pw.w.castAbility(imp, "heal", imp.id); rej != nil {
		t.Fatalf("castAbility heal: %+v", rej)
	}
	if imp.hp != 35 {
		t.Fatalf("imp hp=%d, want 35", imp.hp)
	}
	if len(pw.events(EvCast)) != 1 {
		t.Fatalf("cast events=%d, want 1", len(pw.events(EvCast)))
	}
	if pw.events(EvCast)[0]["npc"] != float64(imp.id) {
		t.Fatalf("cast log missing npc: %v", pw.events(EvCast)[0])
	}
	if len(pw.events(EvCastEffect)) != 1 {
		t.Fatalf("cast_effect events=%d, want 1", len(pw.events(EvCastEffect)))
	}
}

func TestNPCCombatantCastTicksFireballDamagesPlayer(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	alice.pos = Point{X: 4, Z: 0}
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatalf("seed dummies: %v", err)
	}
	caster := pw.w.npcByFaction(FactionHostile)
	caster.pos = Point{X: 0, Z: 0}

	if rej := pw.w.castAbility(caster, "fireball", alice.id); rej != nil {
		t.Fatalf("castAbility fireball: %+v", rej)
	}
	if !caster.casting() {
		t.Fatal("expected pending fireball on npc combatant")
	}
	if alice.hp != MaxHP {
		t.Fatalf("damage applied before cast finished: hp=%d", alice.hp)
	}
	total := caster.castTotal
	if total < 1 {
		t.Fatalf("castTotal=%d, want cast_ticks>0", total)
	}
	pw.w.stepNForTest(total)
	if alice.hp != MaxHP-40 {
		t.Fatalf("alice hp=%d, want %d", alice.hp, MaxHP-40)
	}
	if caster.casting() {
		t.Fatal("npc cast survived resolve")
	}
	if len(pw.events(EvCastBegin)) != 1 {
		t.Fatalf("cast_begin=%d, want 1", len(pw.events(EvCastBegin)))
	}
	if pw.events(EvCastBegin)[0]["npc"] != float64(caster.id) {
		t.Fatalf("cast_begin missing npc: %v", pw.events(EvCastBegin)[0])
	}
	if len(pw.events(EvCastEffect)) != 1 {
		t.Fatalf("cast_effect=%d, want 1", len(pw.events(EvCastEffect)))
	}
}
