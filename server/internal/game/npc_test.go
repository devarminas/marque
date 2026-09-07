package game

import (
	"strings"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestSeedPracticeDummiesWelcome(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	alice := pw.join()
	states := pw.w.npcStates()
	if len(states) != 2 {
		t.Fatalf("npcs=%d, want 2", len(states))
	}
	var friendly, hostile *mnet.NpcState
	for i := range states {
		s := &states[i]
		switch s.Faction {
		case FactionFriendly:
			friendly = s
		case FactionHostile:
			hostile = s
		}
	}
	if friendly == nil || hostile == nil {
		t.Fatalf("states=%v", states)
	}
	if friendly.Kind != KindDummy || hostile.Kind != KindDummy {
		t.Fatalf("kinds friendly=%q hostile=%q", friendly.Kind, hostile.Kind)
	}
	if friendly.X != FriendlyDummyX || hostile.X != EnemyDummyX {
		t.Fatalf("positions friendly=%v,%v hostile=%v,%v", friendly.X, friendly.Z, hostile.X, hostile.Z)
	}
	if friendly.ID == alice.id || hostile.ID == alice.id {
		t.Fatal("dummy id collided with player")
	}
	if friendly.HP != MaxHP || hostile.HP != MaxHP {
		t.Fatalf("hp friendly=%d hostile=%d", friendly.HP, hostile.HP)
	}
	spawned := pw.events(EvNpcSpawned)
	if len(spawned) != 2 {
		t.Fatalf("npc_spawned=%d, want 2", len(spawned))
	}
}

func TestDummiesDoNotWander(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	before := map[mnet.PlayerID]Point{}
	for id, n := range pw.w.npcs {
		before[id] = n.pos
	}
	pw.stepN(20)
	for id, n := range pw.w.npcs {
		if n.pos != before[id] {
			t.Fatalf("npc %d moved from %v to %v", id, before[id], n.pos)
		}
	}
}

func TestPlayerJoinNeverEntersNpcIDBand(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.nextID = practiceNpcIDBand - 1
	conn := pw.dial("")

	if got := len(pw.w.order); got != 0 {
		t.Fatalf("player joined at band boundary: %d in order", got)
	}
	if _, ok := pw.w.byConn[conn]; ok {
		t.Fatal("refused join kept its conn bound")
	}
	logs := pw.logs.String()
	if !strings.Contains(logs, "join_refused") {
		t.Fatalf("join_refused not logged: %s", logs)
	}
}

func TestCastFireballDamagesEnemyDummyOnly(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSONWithHealRange))
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	alice := pw.join()
	friendly := pw.w.npcByFaction(FactionFriendly)
	hostile := pw.w.npcByFaction(FactionHostile)
	friendlyHP := friendly.hp
	hostile.hp = MaxHP

	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: hostile.id}, 1)
	if hostile.hp != MaxHP-40 {
		t.Fatalf("hostile hp=%d, want %d", hostile.hp, MaxHP-40)
	}
	if friendly.hp != friendlyHP {
		t.Fatalf("friendly hp changed to %d", friendly.hp)
	}

	beforeMana := alice.mana
	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: friendly.id}, 2)
	if friendly.hp != friendlyHP {
		t.Fatalf("fireball on friendly changed hp to %d", friendly.hp)
	}
	if alice.mana != beforeMana {
		t.Fatalf("mana spent on wrong-faction cast: %d", alice.mana)
	}
	got := pw.events(EvCastRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonWrongTarget) {
		t.Fatalf("cast_rejected=%v, want wrong_target", got)
	}
}

func TestCastHealHelpsFriendlyDummyOnly(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSONWithHealRange))
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	alice := pw.join()
	friendly := pw.w.npcByFaction(FactionFriendly)
	hostile := pw.w.npcByFaction(FactionHostile)
	friendly.hp = 40
	hostile.hp = 40

	pw.w.cast(alice, mnet.Cast{Ability: "heal", Player: friendly.id}, 1)
	if friendly.hp != 65 {
		t.Fatalf("friendly hp=%d, want 65", friendly.hp)
	}

	beforeMana := alice.mana
	pw.w.cast(alice, mnet.Cast{Ability: "heal", Player: hostile.id}, 2)
	if hostile.hp != 40 {
		t.Fatalf("heal on hostile changed hp to %d", hostile.hp)
	}
	if alice.mana != beforeMana {
		t.Fatalf("mana spent on wrong-faction heal: %d", alice.mana)
	}
	got := pw.events(EvCastRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonWrongTarget) {
		t.Fatalf("cast_rejected=%v, want wrong_target", got)
	}
}

func TestAttackFriendlyDummyRefused(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	alice := pw.join()
	friendly := pw.w.npcByFaction(FactionFriendly)
	beforeHP := friendly.hp

	pw.w.attack(alice, mnet.Attack{Player: friendly.id}, 1)
	if alice.attackTarget != 0 {
		t.Fatalf("attackTarget=%d, want 0", alice.attackTarget)
	}
	if friendly.hp != beforeHP {
		t.Fatalf("friendly hp=%d, want %d", friendly.hp, beforeHP)
	}
	if got := pw.events(EvAttack); len(got) != 0 {
		t.Fatalf("attack events=%v, want none", got)
	}
	got := pw.events(EvAttackRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonWrongTarget) {
		t.Fatalf("attack_rejected=%v, want wrong_target", got)
	}
}

func TestAttackHostileDummyEngagesAndHits(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	alice := pw.join()
	hostile := pw.w.npcByFaction(FactionHostile)
	alice.pos = hostile.pos

	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 1)
	if alice.attackTarget != hostile.id {
		t.Fatalf("attackTarget=%d, want %d", alice.attackTarget, hostile.id)
	}
	if got := pw.events(EvAttack); len(got) != 1 {
		t.Fatalf("attack events=%v, want one", got)
	}
	for range AttackPeriodTicks {
		pw.w.step()
	}
	if hostile.hp != MaxHP-AttackDamage {
		t.Fatalf("hostile hp=%d, want %d", hostile.hp, MaxHP-AttackDamage)
	}
	if got := pw.events(EvAttackHit); len(got) != 1 {
		t.Fatalf("attack_hit=%v, want one", got)
	}
}

func (w *World) npcByFaction(faction string) *npc {
	for _, id := range w.npcOrder {
		n := w.npcs[id]
		if n != nil && n.faction == faction {
			return n
		}
	}
	panic("no npc for faction " + faction)
}

const sharedAbilitiesJSONWithHealRange = `{
  "abilities": [
    {
      "id": "heal",
      "name": "Heal",
      "mana_cost": 20,
      "cooldown_ticks": 10,
      "range": 8,
      "target": "friendly",
      "effect": {"kind": "heal", "amount": 25},
      "ui": {"hotbar_slot": 1, "color": "green"}
    },
    {
      "id": "fireball",
      "name": "Fireball",
      "mana_cost": 35,
      "cooldown_ticks": 8,
      "range": 8,
      "target": "hostile",
      "effect": {"kind": "damage", "amount": 40},
      "ui": {"hotbar_slot": 2, "color": "red"}
    }
  ]
}`
