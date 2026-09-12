package game

import (
	"testing"
)

func TestImpThinkCastSkillFireballDamagesPlayer(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)

	imp.pos = Point{X: 0, Z: 0}
	imp.home = imp.pos
	alice.pos = Point{X: 4, Z: 0}
	imp.phase = phaseThink
	imp.attackTarget = alice.id
	imp.thinkProgress = 0
	imp.thinkCount = ImpCastEvery - 1
	imp.remaining = nil
	before := alice.hp

	for range ImpThinkTicks {
		pw.w.step()
	}
	if imp.phase != phaseCastSkill {
		t.Fatalf("phase=%d after Think, want CastSkill", imp.phase)
	}
	if !imp.casting() || imp.castAbility != ImpSkillID {
		t.Fatalf("casting=%v ability=%q, want %s", imp.casting(), imp.castAbility, ImpSkillID)
	}
	if alice.hp != before {
		t.Fatalf("damage before cast finished: hp=%d", alice.hp)
	}

	total := imp.castTotal
	if total < 1 {
		t.Fatalf("castTotal=%d", total)
	}
	pw.w.stepNForTest(total)
	if alice.hp != before-40 {
		t.Fatalf("alice hp=%d, want %d", alice.hp, before-40)
	}
	if imp.casting() {
		t.Fatal("cast survived resolve")
	}
	pw.w.step()
	if imp.phase != phaseThink {
		t.Fatalf("phase=%d after cast, want Think", imp.phase)
	}
	if len(pw.events(EvCastEffect)) != 1 {
		t.Fatalf("cast_effect=%d, want 1", len(pw.events(EvCastEffect)))
	}
	if pw.events(EvCastEffect)[0]["npc"] != float64(imp.id) {
		t.Fatalf("cast_effect missing npc: %v", pw.events(EvCastEffect)[0])
	}
}

func TestImpLeashCancelsPendingCast(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)

	imp.home = Point{X: 0, Z: 0}
	imp.pos = Point{X: ImpLeashRange + 1, Z: 0}
	alice.pos = Point{X: ImpLeashRange + 1, Z: 1}
	imp.phase = phaseCastSkill
	imp.attackTarget = alice.id
	imp.remaining = nil
	if rej := pw.w.castAbility(imp, ImpSkillID, alice.id); rej != nil {
		t.Fatalf("castAbility: %+v", rej)
	}
	if !imp.casting() {
		t.Fatal("expected pending cast")
	}

	pw.w.step()
	if imp.phase != phaseReturn {
		t.Fatalf("phase=%d, want Return", imp.phase)
	}
	if imp.casting() {
		t.Fatal("cast survived leash")
	}
	cancelled := pw.events(EvCastCancelled)
	if len(cancelled) != 1 || cancelled[0]["cause"] != CauseLeash {
		t.Fatalf("cast_cancelled=%v, want cause=%s", cancelled, CauseLeash)
	}
	if alice.hp != MaxHP {
		t.Fatalf("leash must not resolve cast: hp=%d", alice.hp)
	}
}

func TestImpPathMoveInterruptsCast(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)

	imp.home = Point{X: 0, Z: 0}
	imp.pos = Point{X: 0, Z: 0}
	alice.pos = Point{X: 3, Z: 0}
	imp.phase = phaseCastSkill
	imp.attackTarget = alice.id
	if rej := pw.w.castAbility(imp, ImpSkillID, alice.id); rej != nil {
		t.Fatalf("castAbility: %+v", rej)
	}
	if !imp.casting() {
		t.Fatal("expected pending cast")
	}
	pw.w.assignNPCPath(imp, Point{X: 5, Z: 0})
	if len(imp.remaining) == 0 {
		t.Fatal("expected path to walk")
	}

	pw.w.step()
	if imp.casting() {
		t.Fatal("interrupt_on_move cast survived path advance")
	}
	cancelled := pw.events(EvCastCancelled)
	if len(cancelled) != 1 || cancelled[0]["cause"] != CauseMove {
		t.Fatalf("cast_cancelled=%v, want cause=%s", cancelled, CauseMove)
	}
}
