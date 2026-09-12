package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestPlayerEntersCombatOnDealDamage(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	alice.pos = hostile.pos

	if alice.inCombat(pw.w.tick) {
		t.Fatal("expected out of combat before hit")
	}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 1)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	if !alice.inCombat(pw.w.tick) {
		t.Fatal("expected in combat after dealing melee damage")
	}
}

func TestPlayerEntersCombatOnTakeDamage(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	alice.pos = imp.pos
	imp.phase = phaseCombat
	imp.attackTarget = alice.id
	imp.remaining = nil

	for range pw.npcPeriod(imp) {
		pw.w.step()
	}
	if !alice.inCombat(pw.w.tick) {
		t.Fatal("expected in combat after taking imp damage")
	}
}

func TestPlayerLeavesCombatAfterTimeout(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	pw.w.markCombat(alice)
	if !alice.inCombat(pw.w.tick) {
		t.Fatal("expected in combat right after mark")
	}
	pw.stepN(int(CombatTimeoutTicks))
	if alice.inCombat(pw.w.tick) {
		t.Fatalf("still in combat at tick=%d expires=%d timeout=%d", pw.w.tick, alice.combatExpiresTick, CombatTimeoutTicks)
	}
}

func TestCombatTimeoutRefreshesOnNewEvent(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	pw.w.markCombat(alice)
	pw.stepN(int(CombatTimeoutTicks) - 2)
	if !alice.inCombat(pw.w.tick) {
		t.Fatal("expected still in combat before timeout")
	}
	pw.w.markCombat(alice)
	pw.stepN(int(CombatTimeoutTicks) - 2)
	if !alice.inCombat(pw.w.tick) {
		t.Fatal("expected refresh to keep combat active")
	}
}

func TestDeathClearsCombat(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	pw.w.markCombat(alice)
	alice.hp = 0
	pw.w.kill(alice, 0)
	if alice.inCombat(pw.w.tick) {
		t.Fatal("dead player must leave combat")
	}
}

func TestRespawnClearsCombat(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	alice.hp = 0
	alice.combatExpiresTick = pw.w.tick + CombatTimeoutTicks
	pw.w.respawnPlayer(alice, 1)
	if alice.inCombat(pw.w.tick) {
		t.Fatal("respawn must clear combat")
	}
}

func TestCastDamageMarksCombat(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("mage")
	hostile := pw.seedHostile()
	alice.pos = hostile.pos
	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: hostile.id}, 1)
	if alice.castTotal == 0 {
		t.Fatal("expected cast to begin")
	}
	pw.w.stepNForTest(alice.castTotal)
	if !alice.inCombat(pw.w.tick) {
		t.Fatal("expected in combat after fireball damage")
	}
}
