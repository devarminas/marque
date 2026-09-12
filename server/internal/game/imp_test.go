package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestImpPatrolsNearHome(t *testing.T) {
	pw := newProbeWorld(t)
	seedDeterministicCamp(t, pw.w)
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

func TestImpAggroNearestPlayerInThreatRange(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	bob := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.remaining = nil
	imp.patrolOut = false
	alice.pos = Point{X: imp.home.X + 7, Z: imp.home.Z}
	bob.pos = Point{X: imp.home.X + 6, Z: imp.home.Z}

	pw.w.step()
	if !impInCombatBrain(imp) || imp.attackTarget != bob.id {
		t.Fatalf("phase=%d target=%d, want combat brain on nearest bob=%d (alice=%d)", imp.phase, imp.attackTarget, bob.id, alice.id)
	}
	if imp.phase != phaseApproach {
		t.Fatalf("phase=%d after aggro, want Approach", imp.phase)
	}
	aggro := pw.events(EvNpcAggro)
	if len(aggro) != 1 || aggro[0]["target"] != float64(bob.id) {
		t.Fatalf("npc_aggro=%v", aggro)
	}
	if !bob.inCombat(pw.w.tick) {
		t.Fatal("nearest aggro target should be in combat")
	}
	if alice.inCombat(pw.w.tick) {
		t.Fatal("farther player should not enter combat from someone else's aggro")
	}
}

func TestImpAggroNearestWhenEarlierJoinerIsCloser(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	bob := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.remaining = nil
	imp.patrolOut = false
	alice.pos = Point{X: imp.home.X + 5, Z: imp.home.Z}
	bob.pos = Point{X: imp.home.X + 7, Z: imp.home.Z}

	pw.w.step()
	if !impInCombatBrain(imp) || imp.attackTarget != alice.id {
		t.Fatalf("phase=%d target=%d, want nearest earlier-joiner alice=%d (bob=%d)", imp.phase, imp.attackTarget, alice.id, bob.id)
	}
}

func TestImpAggroEqualDistanceKeepsJoinOrder(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	bob := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.remaining = nil
	imp.patrolOut = false
	alice.pos = Point{X: imp.home.X + 6, Z: imp.home.Z}
	bob.pos = Point{X: imp.home.X + 6, Z: imp.home.Z}

	pw.w.step()
	if !impInCombatBrain(imp) || imp.attackTarget != alice.id {
		t.Fatalf("phase=%d target=%d, want join-order tie-break alice=%d (bob=%d)", imp.phase, imp.attackTarget, alice.id, bob.id)
	}
}

func TestImpNoAggroOutsideThreatRange(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.remaining = nil
	alice.pos = Point{X: imp.home.X + ImpThreatRange + 1, Z: imp.home.Z}

	pw.w.step()
	if impInCombatBrain(imp) {
		t.Fatal("aggroed outside threat range")
	}
	if got := pw.events(EvNpcAggro); len(got) != 0 {
		t.Fatalf("npc_aggro=%v", got)
	}
}

func TestImpLeashClearsCombatAndReturnsHome(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	alice.pos = Point{X: imp.home.X + 100, Z: imp.home.Z}
	imp.phase = phaseAttack
	imp.attackTarget = alice.id
	imp.pos = Point{X: imp.home.X + ImpLeashRange + 1, Z: imp.home.Z}
	imp.remaining = nil

	pw.w.step()
	if imp.phase != phaseReturn {
		t.Fatalf("phase=%d, want return", imp.phase)
	}
	if imp.attackTarget != 0 {
		t.Fatalf("target=%d after leash, want 0", imp.attackTarget)
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
	if imp.phase != phasePatrol {
		t.Fatalf("never finished return: phase=%d pos=%v", imp.phase, imp.pos)
	}
	if distanceBetween(imp.pos, imp.home) > MinPathLength {
		t.Fatalf("not home after return: %v", imp.pos)
	}
	if !hasNPCArrived(pw.events(EvArrived), imp.id) {
		t.Fatal("expected arrived with npc after leash return / snap home")
	}
}

func TestImpChasePathLogsArrived(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.remaining = nil
	imp.patrolOut = false
	imp.pos = imp.home
	alice.pos = Point{X: imp.home.X + 5, Z: imp.home.Z}

	pw.w.step()
	if imp.phase != phaseApproach || len(imp.remaining) == 0 {
		t.Fatalf("expected chase path after aggro, phase=%d rem=%d", imp.phase, len(imp.remaining))
	}
	before := len(pw.events(EvArrived))

	for i := 0; i < 200 && len(imp.remaining) > 0; i++ {
		pw.w.step()
	}
	if len(imp.remaining) > 0 {
		t.Fatal("chase never stopped walking")
	}
	if distanceBetween(imp.pos, alice.pos) > AttackRange {
		t.Fatalf("expected melee range after chase, dist=%v", distanceBetween(imp.pos, alice.pos))
	}

	var npcArrivals []map[string]any
	for _, ev := range pw.events(EvArrived)[before:] {
		if ev["player"] != nil {
			t.Fatalf("npc chase arrived must not set player: %v", ev)
		}
		if ev["npc"] == float64(imp.id) {
			npcArrivals = append(npcArrivals, ev)
		}
	}
	if len(npcArrivals) == 0 {
		t.Fatal("expected arrived with npc after chase path")
	}
	last := npcArrivals[len(npcArrivals)-1]
	if last["x"] == nil || last["z"] == nil {
		t.Fatalf("arrived missing coords: %v", last)
	}
}

func TestPlayerApproachDoesNotLogArrived(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	alice.pos = Point{}
	dest := Point{X: 2, Z: 0}
	if !pw.w.steerToward(alice, dest) {
		t.Fatal("expected approach steer")
	}
	for i := 0; i < 80 && distanceBetween(alice.pos, dest) > MinPathLength; i++ {
		pw.w.step()
	}
	alice.clearSteer()
	if got := pw.events(EvArrived); len(got) != 0 {
		t.Fatalf("player approach must not log path arrived, got %v", got)
	}
	if got := pw.events(EvPathAssigned); len(got) != 0 {
		t.Fatalf("player approach must not assign path, got %v", got)
	}
}

func hasNPCArrived(events []map[string]any, id mnet.PlayerID) bool {
	for _, ev := range events {
		if ev["npc"] == float64(id) {
			return true
		}
	}
	return false
}

func TestImpMeleeDamagesPlayer(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	alice.pos = imp.pos
	imp.phase = phaseAttack
	imp.attackTarget = alice.id
	imp.remaining = nil
	before := alice.hp

	for range pw.npcPeriod(imp) {
		pw.w.step()
	}
	if alice.hp != before-ImpDamage {
		t.Fatalf("hp=%d, want %d", alice.hp, before-ImpDamage)
	}
	if imp.phase != phaseThink {
		t.Fatalf("phase=%d after swing, want Think", imp.phase)
	}
	hits := pw.events(EvAttackHit)
	if len(hits) != 1 {
		t.Fatalf("attack_hit=%v", hits)
	}
	if hits[0]["damage"] != float64(ImpDamage) || hits[0]["npc"] != float64(imp.id) {
		t.Fatalf("hit fields=%v", hits[0])
	}
}

func TestImpAttackGatedByThink(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	alice.pos = imp.pos
	imp.phase = phaseAttack
	imp.attackTarget = alice.id
	imp.remaining = nil
	before := alice.hp

	for range pw.npcPeriod(imp) {
		pw.w.step()
	}
	if alice.hp != before-ImpDamage {
		t.Fatalf("first swing hp=%d, want %d", alice.hp, before-ImpDamage)
	}
	if imp.phase != phaseThink {
		t.Fatalf("phase=%d, want Think after Attack", imp.phase)
	}

	for range ImpThinkTicks - 1 {
		pw.w.step()
		if imp.phase != phaseThink {
			t.Fatalf("left Think early: phase=%d", imp.phase)
		}
	}
	if alice.hp != before-ImpDamage {
		t.Fatalf("swung during Think: hp=%d", alice.hp)
	}
}

func TestImpThinkReturnsToAttack(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	alice.pos = imp.pos
	imp.phase = phaseThink
	imp.attackTarget = alice.id
	imp.thinkProgress = 0
	imp.thinkCount = 0
	imp.remaining = nil

	for range ImpThinkTicks {
		pw.w.step()
	}
	if imp.phase != phaseAttack {
		t.Fatalf("phase=%d after Think, want Attack", imp.phase)
	}
}

func TestImpThinkApproachesWhenTargetOutOfRange(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.pos = imp.home
	alice.pos = Point{X: imp.home.X + AttackRange + 2, Z: imp.home.Z}
	imp.phase = phaseThink
	imp.attackTarget = alice.id
	imp.thinkProgress = 0
	imp.thinkCount = 0
	imp.remaining = nil

	for range ImpThinkTicks {
		pw.w.step()
	}
	if imp.phase != phaseApproach {
		t.Fatalf("phase=%d after Think, want Approach", imp.phase)
	}
	if len(imp.remaining) == 0 {
		t.Fatal("Approach assigned no path toward target")
	}
}

func TestImpCombatTransitionPatrolToAttack(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.remaining = nil
	imp.patrolOut = false
	imp.pos = imp.home
	alice.pos = Point{X: imp.home.X + AttackRange*0.5, Z: imp.home.Z}

	pw.w.step()
	if imp.phase != phaseAttack {
		t.Fatalf("phase=%d after in-range aggro, want Attack", imp.phase)
	}
	if len(pw.events(EvNpcAggro)) != 1 {
		t.Fatalf("npc_aggro=%v", pw.events(EvNpcAggro))
	}
}

func TestCombatClassCanAttackImp(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	alice.pos = imp.pos

	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 1)
	if alice.attackTarget != imp.id {
		t.Fatalf("attackTarget=%d, want %d", alice.attackTarget, imp.id)
	}
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	if imp.hp != ImpMaxHP-AttackDamage {
		t.Fatalf("imp hp=%d, want %d", imp.hp, ImpMaxHP-AttackDamage)
	}
}

func TestGatheringClassCannotAttackImp(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("lumberjack")
	seedDeterministicCamp(t, pw.w)
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

func despawnOtherImps(w *World, keep *npc) {
	for _, id := range append([]mnet.PlayerID(nil), w.npcOrder...) {
		n := w.npcs[id]
		if n == nil || n.kind != KindImp || n == keep {
			continue
		}
		w.despawnNPC(n)
	}
}

func impInCombatBrain(n *npc) bool {
	switch n.phase {
	case phaseAggro, phaseApproach, phaseAttack, phaseThink, phaseCastSkill:
		return true
	default:
		return false
	}
}

