package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestSeedImpCampWelcome(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	states := pw.w.npcStates()
	if len(states) != 1 {
		t.Fatalf("npcs=%d, want 1", len(states))
	}
	s := states[0]
	if s.Kind != KindImp || s.Faction != FactionHostile {
		t.Fatalf("state=%+v", s)
	}
	if s.X != ImpCampX || s.Z != ImpCampZ {
		t.Fatalf("pos=%v,%v want %v,%v", s.X, s.Z, ImpCampX, ImpCampZ)
	}
	if s.HP != ImpMaxHP || s.MaxHP != ImpMaxHP {
		t.Fatalf("hp=%d/%d, want %d", s.HP, s.MaxHP, ImpMaxHP)
	}
	imp := pw.w.npcByKind(KindImp)
	if imp == nil || imp.home != (Point{X: ImpCampX, Z: ImpCampZ}) {
		t.Fatalf("home unset: %+v", imp)
	}
	if got := pw.events(EvNpcSpawned); len(got) != 1 {
		t.Fatalf("npc_spawned=%v", got)
	}
}

func TestImpPatrolsNearHome(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	start := imp.pos
	pw.stepN(5)
	if imp.pos == start && len(imp.remaining) == 0 {
		t.Fatal("imp never left idle at home")
	}
	if distanceBetween(imp.pos, imp.home) > ImpPatrolRadius+0.5 {
		t.Fatalf("imp wandered too far: pos=%v home=%v", imp.pos, imp.home)
	}
	paths := pw.events(EvPathAssigned)
	if len(paths) == 0 {
		t.Fatal("patrol assigned no server path")
	}
	if paths[0]["npc"] == nil {
		t.Fatalf("path log missing npc: %v", paths[0])
	}
}

func TestImpAggroFirstPlayerInThreatRange(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	bob := pw.joinWithClass("knight")
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	imp.remaining = nil
	imp.patrolOut = false
	alice.pos = Point{X: ImpCampX + 7, Z: ImpCampZ}
	bob.pos = Point{X: ImpCampX + 6, Z: ImpCampZ}

	pw.w.step()
	if imp.phase != phaseCombat || imp.target != alice.id {
		t.Fatalf("phase=%d target=%d, want combat on first-in-order alice=%d (bob=%d)", imp.phase, imp.target, alice.id, bob.id)
	}
	aggro := pw.events(EvNpcAggro)
	if len(aggro) != 1 || aggro[0]["target"] != float64(alice.id) {
		t.Fatalf("npc_aggro=%v", aggro)
	}
}

func TestImpNoAggroOutsideThreatRange(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	imp.remaining = nil
	alice.pos = Point{X: ImpCampX + ImpThreatRange + 1, Z: ImpCampZ}

	pw.w.step()
	if imp.phase == phaseCombat {
		t.Fatal("aggroed outside threat range")
	}
	if got := pw.events(EvNpcAggro); len(got) != 0 {
		t.Fatalf("npc_aggro=%v", got)
	}
}

func TestImpLeashClearsCombatAndReturnsHome(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	alice.pos = Point{X: ImpCampX + 100, Z: ImpCampZ}
	imp.phase = phaseCombat
	imp.target = alice.id
	imp.pos = Point{X: ImpCampX + ImpLeashRange + 1, Z: ImpCampZ}
	imp.remaining = nil

	pw.w.step()
	if imp.phase != phaseReturn {
		t.Fatalf("phase=%d, want return", imp.phase)
	}
	if imp.target != 0 {
		t.Fatalf("target=%d after leash, want 0", imp.target)
	}
	leash := pw.events(EvNpcLeash)
	if len(leash) != 1 || leash[0]["target"] != float64(alice.id) {
		t.Fatalf("npc_leash=%v", leash)
	}
	if len(imp.remaining) == 0 && imp.pos != imp.home {
		t.Fatal("leash assigned no path home")
	}

	for i := 0; i < 200 && imp.phase == phaseReturn; i++ {
		pw.w.step()
	}
	if imp.phase != phaseIdle {
		t.Fatalf("never finished return: phase=%d pos=%v", imp.phase, imp.pos)
	}
	if distanceBetween(imp.pos, imp.home) > MinPathLength {
		t.Fatalf("not home after return: %v", imp.pos)
	}
}

func TestImpMeleeDamagesPlayer(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	alice.pos = imp.pos
	imp.phase = phaseCombat
	imp.target = alice.id
	imp.remaining = nil
	before := alice.hp

	for range AttackPeriodTicks {
		pw.w.step()
	}
	if alice.hp != before-ImpDamage {
		t.Fatalf("hp=%d, want %d", alice.hp, before-ImpDamage)
	}
	hits := pw.events(EvAttackHit)
	if len(hits) != 1 {
		t.Fatalf("attack_hit=%v", hits)
	}
	if hits[0]["damage"] != float64(ImpDamage) || hits[0]["npc"] != float64(imp.id) {
		t.Fatalf("hit fields=%v", hits[0])
	}
}

func TestCombatClassCanAttackImp(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	alice.pos = imp.pos

	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 1)
	if alice.attackTarget != imp.id {
		t.Fatalf("attackTarget=%d, want %d", alice.attackTarget, imp.id)
	}
	for range AttackPeriodTicks {
		pw.w.step()
	}
	if imp.hp != ImpMaxHP-AttackDamage {
		t.Fatalf("imp hp=%d, want %d", imp.hp, ImpMaxHP-AttackDamage)
	}
}

func TestGatheringClassCannotAttackImp(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("lumberjack")
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	before := imp.hp
	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 1)
	if alice.attackTarget != 0 {
		t.Fatalf("attackTarget=%d", alice.attackTarget)
	}
	if imp.hp != before {
		t.Fatalf("hp changed to %d", imp.hp)
	}
	got := pw.events(EvAttackRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonNeedsClass) {
		t.Fatalf("attack_rejected=%v", got)
	}
}

func TestImpDeathRemovesInstanceAndLogs(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	if err := pw.w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	impID := imp.id
	alice.pos = imp.pos
	imp.hp = AttackDamage

	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 1)
	for range AttackPeriodTicks {
		pw.w.step()
	}
	if _, ok := pw.w.npcs[impID]; ok {
		t.Fatal("dead imp still in world")
	}
	if pw.w.npcByKind(KindImp) != nil {
		t.Fatal("imp kind still present after death")
	}
	deaths := pw.events(EvDeath)
	if len(deaths) != 1 || deaths[0]["npc"] != float64(impID) {
		t.Fatalf("death=%v", deaths)
	}
	if alice.attackTarget != 0 {
		t.Fatalf("attacker still locked on despawned imp: %d", alice.attackTarget)
	}
}
