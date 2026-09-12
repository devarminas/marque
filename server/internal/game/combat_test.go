package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/weapondef"
)

func TestFreshPlayerHasMaxHP(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	if alice.hp != MaxHP {
		t.Fatalf("hp=%d, want %d", alice.hp, MaxHP)
	}
	state := alice.wireState()
	if state.HP != MaxHP || state.MaxHP != MaxHP {
		t.Fatalf("wireState=%+v, want hp and max_hp %d", state, MaxHP)
	}
}

func TestAttackOutOfRangeSteersInThenHitsOnPeriod(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	hostile.pos = Point{X: 5, Z: 0}
	alice.pos = Point{X: 0, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	if alice.attackTarget != hostile.id {
		t.Fatalf("attackTarget=%d, want %d", alice.attackTarget, hostile.id)
	}
	if !alice.steering() {
		t.Fatal("out-of-range attack assigned no approach steer")
	}
	if got := pw.events(EvPathAssigned); len(got) != 0 {
		t.Fatalf("attack approach must not assign player path, got %v", got)
	}
	if hostile.hp != DummyMaxHP {
		t.Fatal("hit landed before arrival")
	}

	for i := 0; i < 80 && distanceBetween(alice.pos, hostile.pos) > AttackRange; i++ {
		pw.w.step()
	}
	if distanceBetween(alice.pos, hostile.pos) > AttackRange {
		t.Fatal("never entered AttackRange")
	}
	if hostile.hp != DummyMaxHP {
		t.Fatalf("hit on first in-range contact: hp=%d", hostile.hp)
	}
	if alice.attackProgress < 1 {
		t.Fatalf("in-range arrival did not start the period: progress=%d", alice.attackProgress)
	}

	for alice.attackProgress > 0 && hostile.hp == DummyMaxHP {
		pw.w.step()
	}
	if hostile.hp != DummyMaxHP-AttackDamage {
		t.Fatalf("hp=%d after first period, want %d", hostile.hp, DummyMaxHP-AttackDamage)
	}
	if got := pw.events(EvAttackHit); len(got) != 1 {
		t.Fatalf("logged %d attack_hit, want 1", len(got))
	}
}

func TestNoHitOnFirstInRangeTickWhenPeriodPositive(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	if pw.playerPeriod(alice) < 1 {
		t.Fatal("test assumes player attack period > 0")
	}
	hostile := pw.seedHostile()
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	pw.w.step()
	if alice.attackProgress != 1 {
		t.Fatalf("progress=%d after first in-range tick, want 1", alice.attackProgress)
	}
	if hostile.hp != DummyMaxHP {
		t.Fatalf("hit on first in-range tick: hp=%d", hostile.hp)
	}
}

func TestAttackPeriodPausesOffRange(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	pw.w.step()
	pw.w.step()
	if alice.attackProgress != 2 {
		t.Fatalf("progress=%d after two in-range ticks, want 2", alice.attackProgress)
	}

	hostile.pos = Point{X: 10, Z: 0}
	pw.w.step()
	if alice.attackProgress != 2 {
		t.Fatalf("progress reset off-range: got %d, want paused 2", alice.attackProgress)
	}
	if hostile.hp != DummyMaxHP {
		t.Fatalf("out-of-range hit: hp=%d", hostile.hp)
	}

	hostile.pos = Point{X: 1, Z: 0}
	alice.clearSteer()
	alice.pos = Point{X: 0, Z: 0}
	pw.w.step()
	pw.w.step()
	if hostile.hp != DummyMaxHP-AttackDamage {
		t.Fatalf("hp=%d after resume to period, want %d", hostile.hp, DummyMaxHP-AttackDamage)
	}
}

func TestMoveCancelsPendingAttackFromCombat(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	pw.w.step()

	pw.w.move(alice, mnet.Move{DX: -1, DZ: 0}, 0)
	if alice.attackTarget != 0 {
		t.Fatalf("pending attack survived move: target=%d", alice.attackTarget)
	}
	cancelled := pw.events(EvAttackCancelled)
	if len(cancelled) != 1 || cancelled[0]["cause"] != CauseMove {
		t.Fatalf("cancel events=%v, want one cause=%s", cancelled, CauseMove)
	}

	before := hostile.hp
	for range pw.playerPeriod(alice) + 2 {
		pw.w.step()
	}
	if hostile.hp != before {
		t.Fatalf("hits continued after cancel: hp %d→%d", before, hostile.hp)
	}
}

func TestTenHitsKillImpFromFull(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	hostile := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, hostile)
	hostile.hp = ImpMaxHP
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)

	hits := 0
	for i := 0; i < 200 && !hostile.dead(); i++ {
		before := hostile.hp
		pw.w.step()
		if hostile.hp < before {
			hits++
		}
	}
	if !hostile.dead() {
		t.Fatalf("imp survived with hp=%d after %d hits", hostile.hp, hits)
	}
	if hits != ImpMaxHP/AttackDamage {
		t.Fatalf("hits=%d, want %d", hits, ImpMaxHP/AttackDamage)
	}
	if alice.attackTarget != 0 {
		t.Fatalf("attacker still pending on corpse: %d", alice.attackTarget)
	}
}

func TestPracticeDummySurvivesLethalVolley(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	hostile.hp = AttackDamage
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)

	for range pw.playerPeriod(alice) * 20 {
		pw.w.step()
	}
	if hostile.dead() || hostile.hp < DummyMinHP {
		t.Fatalf("dummy died or floored below min: hp=%d", hostile.hp)
	}
	if alice.attackTarget != hostile.id {
		t.Fatalf("attacker lost immortal target: %d", alice.attackTarget)
	}
}

func TestDeadRefusesOrdinaryIntents(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	bob.hp = 0

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: bob.conn,
		Msg:  mnet.Move{DX: 1, DZ: 0},
	})
	if bob.steering() {
		t.Fatal("dead player steered")
	}
	if got := pw.events(EvMoveRejected); len(got) != 1 {
		t.Fatalf("logged %d move_rejected, want 1", len(got))
	}
	if got := pw.events(EvMoveRejected)[0]["reason"]; got != string(mnet.ReasonDead) {
		t.Fatalf("reason=%v, want dead", got)
	}

	pw.w.attack(bob, mnet.Attack{Player: alice.id}, 0)
	if bob.attackTarget != 0 {
		t.Fatal("dead attacker set pending")
	}
	if got := pw.events(EvAttackRejected); len(got) != 1 {
		t.Fatalf("logged %d attack_rejected, want 1", len(got))
	}
}

func TestRespawnRestoresAtJoinSpawn(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	alice.hp = 0
	alice.pos = Point{X: 7, Z: 9}
	pw.w.steerToward(alice, Point{X: 8, Z: 9})

	pw.w.respawnPlayer(alice, 3)
	if alice.dead() || alice.hp != MaxHP {
		t.Fatalf("after respawn hp=%d", alice.hp)
	}
	if alice.pos.X != VillageMap.SpawnX || alice.pos.Z != VillageMap.SpawnZ {
		t.Fatalf("pos=%v, want join spawn", alice.pos)
	}
	if alice.steering() {
		t.Fatal("respawn left approach steer")
	}
	if got := pw.events(EvRespawn); len(got) != 1 || got[0]["seq"] != float64(3) {
		t.Fatalf("respawn events=%v", got)
	}
}

func TestLivingRespawnRefused(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.respawnPlayer(alice, 0)
	if alice.hp != MaxHP {
		t.Fatalf("hp changed on refused respawn: %d", alice.hp)
	}
	if got := pw.events(EvRespawnRejected); len(got) != 1 {
		t.Fatalf("logged %d respawn_rejected, want 1", len(got))
	}
	if got := pw.events(EvRespawnRejected)[0]["reason"]; got != string(mnet.ReasonNotDead) {
		t.Fatalf("reason=%v, want not_dead", got)
	}
}

func TestSameTickMultiAttackerJoinOrder(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	bob := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	hostile := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, hostile)
	hostile.hp = AttackDamage
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	bob.pos = Point{X: 0.5, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	pw.w.attack(bob, mnet.Attack{Player: hostile.id}, 0)
	alice.attackProgress = pw.playerPeriod(alice) - 1
	bob.attackProgress = pw.playerPeriod(bob) - 1

	pw.w.step()
	if !hostile.dead() {
		t.Fatalf("imp hp=%d, want 0", hostile.hp)
	}
	hits := pw.events(EvAttackHit)
	if len(hits) != 1 {
		t.Fatalf("hits=%d, want exactly one (join-order first kills)", len(hits))
	}
	if hits[0]["player"] != float64(alice.id) {
		t.Fatalf("winner=%v, want alice id %d", hits[0]["player"], alice.id)
	}
	if bob.attackTarget != 0 {
		t.Fatal("later attacker still pending on corpse")
	}
}

func TestAttackPlayerRefused(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	bob := pw.joinBare()
	bob.pos = Point{X: 1, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: bob.id}, 0)
	if alice.attackTarget != 0 {
		t.Fatalf("attackTarget=%d, want 0", alice.attackTarget)
	}
	if bob.hp != MaxHP {
		t.Fatalf("pvp hit landed: hp=%d", bob.hp)
	}
	got := pw.events(EvAttackRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonWrongTarget) {
		t.Fatalf("attack_rejected=%v, want wrong_target", got)
	}
}

func TestAttackWithoutCombatClassRefused(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinBare()
	hostile := pw.seedHostile()
	alice.pos = hostile.pos

	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	if alice.attackTarget != 0 {
		t.Fatalf("attackTarget=%d, want 0", alice.attackTarget)
	}
	got := pw.events(EvAttackRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonNeedsClass) {
		t.Fatalf("attack_rejected=%v, want needs_class", got)
	}
}

func TestAttackGatheringClassRefused(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("miner")
	hostile := pw.seedHostile()
	alice.pos = hostile.pos

	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	if alice.attackTarget != 0 {
		t.Fatalf("attackTarget=%d, want 0", alice.attackTarget)
	}
	got := pw.events(EvAttackRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonNeedsClass) {
		t.Fatalf("attack_rejected=%v, want needs_class", got)
	}
}

func TestGatheringPlayerStillDiesAndRespawns(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("lumberjack")
	alice.hp = 0
	if !alice.dead() {
		t.Fatal("expected dead")
	}
	pw.w.respawnPlayer(alice, 1)
	if alice.dead() || alice.hp != MaxHP {
		t.Fatalf("after respawn hp=%d", alice.hp)
	}
}

func TestAttackIgnoresWeapon(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	if hostile.hp != DummyMaxHP-AttackDamage {
		t.Fatalf("knight hit failed: hp=%d", hostile.hp)
	}
}

func TestPlayerAttackPeriodFromEquippedWeapon(t *testing.T) {
	pw := newClassProbe(t)
	cat, err := weapondef.Parse([]byte(`{"weapons":[
		{"id":"unarmed","attack_period_ticks":7},
		{"id":"sword","attack_period_ticks":3},
		{"id":"imp_claw","attack_period_ticks":4}
	]}`))
	if err != nil {
		t.Fatal(err)
	}
	pw.w.SetWeapons(cat)
	alice := pw.joinWithClass("knight")
	if got := pw.w.playerWeaponID(alice); got != weapondef.Sword {
		t.Fatalf("weapon=%q, want sword", got)
	}
	if got := pw.playerPeriod(alice); got != 3 {
		t.Fatalf("period=%d, want 3 from sword", got)
	}
	hostile := pw.seedHostile()
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	for range 2 {
		pw.w.step()
	}
	if hostile.hp != DummyMaxHP {
		t.Fatalf("hit before sword period: hp=%d", hostile.hp)
	}
	pw.w.step()
	if hostile.hp != DummyMaxHP-AttackDamage {
		t.Fatalf("hp=%d after sword period, want %d", hostile.hp, DummyMaxHP-AttackDamage)
	}
}

func TestPlayerAndNPCShareWeaponDefPeriod(t *testing.T) {
	pw := newClassProbe(t)
	const sharedPeriod = 2
	cat, err := weapondef.Parse([]byte(`{"weapons":[
		{"id":"unarmed","attack_period_ticks":4},
		{"id":"sword","attack_period_ticks":2},
		{"id":"imp_claw","attack_period_ticks":9}
	]}`))
	if err != nil {
		t.Fatal(err)
	}
	pw.w.SetWeapons(cat)

	alice := pw.joinWithClass("knight")
	if got := pw.w.playerWeaponID(alice); got != weapondef.Sword {
		t.Fatalf("player weapon=%q, want sword", got)
	}
	if got := pw.playerPeriod(alice); got != sharedPeriod {
		t.Fatalf("player period=%d, want %d", got, sharedPeriod)
	}

	hostile := pw.seedHostile()
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	pw.w.step()
	if hostile.hp != DummyMaxHP {
		t.Fatalf("player hit on tick 1: hp=%d", hostile.hp)
	}
	pw.w.step()
	if hostile.hp != DummyMaxHP-AttackDamage {
		t.Fatalf("player hp=%d after shared period, want %d", hostile.hp, DummyMaxHP-AttackDamage)
	}

	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.weapon = weapondef.Sword
	if got := pw.npcPeriod(imp); got != sharedPeriod {
		t.Fatalf("npc period=%d, want %d from shared sword def", got, sharedPeriod)
	}
	if got := pw.weaponPeriod(weapondef.ImpClaw); got != 9 {
		t.Fatalf("imp_claw period=%d, want 9 (must not govern sword NPC)", got)
	}

	bob := pw.joinWithClass("knight")
	bob.pos = imp.pos
	imp.phase = phaseCombat
	imp.target = bob.id
	imp.remaining = nil
	imp.attackProgress = 0
	before := bob.hp
	pw.w.step()
	if bob.hp != before {
		t.Fatalf("npc hit on tick 1: hp=%d", bob.hp)
	}
	pw.w.step()
	if bob.hp != before-ImpDamage {
		t.Fatalf("npc hp=%d after shared sword period, want %d", bob.hp, before-ImpDamage)
	}
}

func (pw *probeWorld) join() *player {
	pw.t.Helper()
	pw.dial("")
	return pw.w.order[len(pw.w.order)-1]
}
