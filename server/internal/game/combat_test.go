package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
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

func TestAttackOutOfRangePathsInThenHitsOnPeriod(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 5, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: bob.id}, 0)
	if alice.attackTarget != bob.id {
		t.Fatalf("attackTarget=%d, want %d", alice.attackTarget, bob.id)
	}
	if !alice.walking() {
		t.Fatal("out-of-range attack assigned no path")
	}
	if bob.hp != MaxHP {
		t.Fatal("hit landed before arrival")
	}

	for i := 0; i < 80 && distanceBetween(alice.pos, bob.pos) > AttackRange; i++ {
		pw.w.step()
	}
	if distanceBetween(alice.pos, bob.pos) > AttackRange {
		t.Fatal("never entered AttackRange")
	}
	if bob.hp != MaxHP {
		t.Fatalf("hit on first in-range contact: hp=%d", bob.hp)
	}
	if alice.attackProgress < 1 {
		t.Fatalf("in-range arrival did not start the period: progress=%d", alice.attackProgress)
	}

	for alice.attackProgress > 0 && bob.hp == MaxHP {
		pw.w.step()
	}
	if bob.hp != MaxHP-AttackDamage {
		t.Fatalf("hp=%d after first period, want %d", bob.hp, MaxHP-AttackDamage)
	}
	if got := pw.events(EvAttackHit); len(got) != 1 {
		t.Fatalf("logged %d attack_hit, want 1", len(got))
	}
}

func TestNoHitOnFirstInRangeTickWhenPeriodPositive(t *testing.T) {
	if AttackPeriodTicks < 1 {
		t.Fatal("test assumes AttackPeriodTicks > 0")
	}
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 1, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: bob.id}, 0)
	pw.w.step()
	if alice.attackProgress != 1 {
		t.Fatalf("progress=%d after first in-range tick, want 1", alice.attackProgress)
	}
	if bob.hp != MaxHP {
		t.Fatalf("hit on first in-range tick: hp=%d", bob.hp)
	}
}

func TestAttackPeriodPausesOffRange(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 1, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: bob.id}, 0)
	pw.w.step()
	pw.w.step()
	if alice.attackProgress != 2 {
		t.Fatalf("progress=%d after two in-range ticks, want 2", alice.attackProgress)
	}

	bob.pos = Point{X: 10, Z: 0}
	pw.w.step()
	if alice.attackProgress != 2 {
		t.Fatalf("progress reset off-range: got %d, want paused 2", alice.attackProgress)
	}
	if bob.hp != MaxHP {
		t.Fatalf("out-of-range hit: hp=%d", bob.hp)
	}

	bob.pos = Point{X: 1, Z: 0}
	alice.remaining = nil
	alice.pos = Point{X: 0, Z: 0}
	pw.w.step()
	pw.w.step()
	if bob.hp != MaxHP-AttackDamage {
		t.Fatalf("hp=%d after resume to period, want %d", bob.hp, MaxHP-AttackDamage)
	}
}

func TestMoveToCancelsPendingAttack(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 1, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: bob.id}, 0)
	pw.w.step()

	pw.w.moveTo(alice, mnet.MoveTo{X: -2, Z: 0}, 0)
	if alice.attackTarget != 0 {
		t.Fatalf("pending attack survived move_to: target=%d", alice.attackTarget)
	}
	cancelled := pw.events(EvAttackCancelled)
	if len(cancelled) != 1 || cancelled[0]["cause"] != CauseMoveTo {
		t.Fatalf("cancel events=%v, want one cause=%s", cancelled, CauseMoveTo)
	}

	before := bob.hp
	for range AttackPeriodTicks + 2 {
		pw.w.step()
	}
	if bob.hp != before {
		t.Fatalf("hits continued after cancel: hp %d→%d", before, bob.hp)
	}
}

func TestTenHitsKillFromFull(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 1, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: bob.id}, 0)

	hits := 0
	for i := 0; i < 200 && !bob.dead(); i++ {
		before := bob.hp
		pw.w.step()
		if bob.hp < before {
			hits++
		}
	}
	if !bob.dead() {
		t.Fatalf("bob survived with hp=%d after %d hits", bob.hp, hits)
	}
	if hits != MaxHP/AttackDamage {
		t.Fatalf("hits=%d, want %d", hits, MaxHP/AttackDamage)
	}
	if bob.hp < 0 {
		t.Fatalf("hp went negative: %d", bob.hp)
	}
	if got := pw.events(EvDeath); len(got) != 1 {
		t.Fatalf("logged %d death, want 1", len(got))
	}
	if alice.attackTarget != 0 {
		t.Fatalf("attacker still pending on corpse: %d", alice.attackTarget)
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
		Msg:  mnet.MoveTo{X: 1, Z: 1},
	})
	if bob.walking() {
		t.Fatal("dead player walked")
	}
	if got := pw.events(EvMoveToRejected); len(got) != 1 {
		t.Fatalf("logged %d move_to_rejected, want 1", len(got))
	}
	if got := pw.events(EvMoveToRejected)[0]["reason"]; got != string(mnet.ReasonDead) {
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
	alice.remaining = []Point{{X: 8, Z: 9}}

	pw.w.respawnPlayer(alice, 3)
	if alice.dead() || alice.hp != MaxHP {
		t.Fatalf("after respawn hp=%d", alice.hp)
	}
	if alice.pos.X != spawnX || alice.pos.Z != spawnZ {
		t.Fatalf("pos=%v, want join spawn", alice.pos)
	}
	if alice.walking() {
		t.Fatal("respawn left a walk in progress")
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
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	carol := pw.join()
	carol.hp = AttackDamage
	carol.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	bob.pos = Point{X: 0.5, Z: 0}

	pw.w.attack(alice, mnet.Attack{Player: carol.id}, 0)
	pw.w.attack(bob, mnet.Attack{Player: carol.id}, 0)
	alice.attackProgress = AttackPeriodTicks - 1
	bob.attackProgress = AttackPeriodTicks - 1

	pw.w.step()
	if !carol.dead() {
		t.Fatalf("carol hp=%d, want 0", carol.hp)
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

func TestSuspendedTargetTakesDamageWithoutPanic(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bobConn := pw.dial("")
	bob := pw.w.order[len(pw.w.order)-1]
	bob.pos = Point{X: 1, Z: 0}
	pw.disconnect(bobConn, mnet.DisconnectPeerGone, "")
	if !bob.suspended() {
		t.Fatal("bob not suspended")
	}

	pw.w.attack(alice, mnet.Attack{Player: bob.id}, 0)
	for range AttackPeriodTicks {
		pw.w.step()
	}
	if bob.hp != MaxHP-AttackDamage {
		t.Fatalf("suspended target hp=%d, want %d", bob.hp, MaxHP-AttackDamage)
	}
}

func TestAttackIgnoresWeapon(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.joinKit = DefaultJoinKit
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 1, Z: 0}
	if len(pw.w.items.Worn(alice.id)) != 0 {
		t.Fatal("alice unexpectedly wearing something")
	}
	pw.w.attack(alice, mnet.Attack{Player: bob.id}, 0)
	for range AttackPeriodTicks {
		pw.w.step()
	}
	if bob.hp != MaxHP-AttackDamage {
		t.Fatalf("unarmed hit failed: hp=%d", bob.hp)
	}
}

func (pw *probeWorld) join() *player {
	pw.t.Helper()
	pw.dial("")
	return pw.w.order[len(pw.w.order)-1]
}
