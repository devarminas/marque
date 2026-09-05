package game

import (
	"testing"

	"github.com/devarminas/marque/server/internal/abilitydef"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestCastFireballDamagesHostileInRange(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 3, Z: 0}
	bob.hp = MaxHP

	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: bob.id}, 1)

	if bob.hp != MaxHP-40 {
		t.Fatalf("bob hp=%d, want %d", bob.hp, MaxHP-40)
	}
	if alice.mana != MaxMana-35 {
		t.Fatalf("alice mana=%d, want %d", alice.mana, MaxMana-35)
	}
	if len(pw.events(EvCast)) != 1 {
		t.Fatalf("cast events=%d, want 1", len(pw.events(EvCast)))
	}
	if len(pw.events(EvCastEffect)) != 1 {
		t.Fatalf("cast_effect events=%d, want 1", len(pw.events(EvCastEffect)))
	}
	if len(pw.events(EvCastRejected)) != 0 {
		t.Fatalf("unexpected cast_rejected: %v", pw.events(EvCastRejected))
	}
}

func TestCastFireballRefusesFriendlySelf(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	before := alice.mana

	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: alice.id}, 1)

	if alice.hp != MaxHP {
		t.Fatalf("self fireball changed hp to %d", alice.hp)
	}
	if alice.mana != before {
		t.Fatalf("mana changed on refuse: %d -> %d", before, alice.mana)
	}
	got := pw.events(EvCastRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonWrongTarget) {
		t.Fatalf("cast_rejected=%v, want wrong_target", got)
	}
}

func TestCastHealRestoresSelf(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	alice.hp = 40

	pw.w.cast(alice, mnet.Cast{Ability: "heal", Player: alice.id}, 1)

	if alice.hp != 65 {
		t.Fatalf("hp=%d, want 65", alice.hp)
	}
	if alice.mana != MaxMana-20 {
		t.Fatalf("mana=%d, want %d", alice.mana, MaxMana-20)
	}
}

func TestCastHealCapsAtMaxHP(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	alice.hp = MaxHP - 5

	pw.w.cast(alice, mnet.Cast{Ability: "heal", Player: alice.id}, 1)

	if alice.hp != MaxHP {
		t.Fatalf("hp=%d, want %d", alice.hp, MaxHP)
	}
}

func TestCastHealRefusesHostileOther(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	bob := pw.join()
	bob.hp = 50
	beforeMana := alice.mana
	beforeHP := bob.hp

	pw.w.cast(alice, mnet.Cast{Ability: "heal", Player: bob.id}, 1)

	if bob.hp != beforeHP {
		t.Fatalf("heal on other changed hp to %d", bob.hp)
	}
	if alice.mana != beforeMana {
		t.Fatalf("mana spent on refuse: %d", alice.mana)
	}
	got := pw.events(EvCastRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonWrongTarget) {
		t.Fatalf("cast_rejected=%v, want wrong_target", got)
	}
}

func TestCastRefusesNoTarget(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	before := alice.mana

	pw.w.cast(alice, mnet.Cast{Ability: "fireball"}, 1)

	if alice.mana != before {
		t.Fatalf("mana changed: %d", alice.mana)
	}
	got := pw.events(EvCastRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonNoTarget) {
		t.Fatalf("cast_rejected=%v, want no_target", got)
	}
}

func TestCastRefusesInsufficientMana(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 2, Z: 0}
	alice.mana = 10
	beforeHP := bob.hp

	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: bob.id}, 1)

	if bob.hp != beforeHP {
		t.Fatalf("hp changed on mana refuse: %d", bob.hp)
	}
	if alice.mana != 10 {
		t.Fatalf("mana=%d, want 10", alice.mana)
	}
	got := pw.events(EvCastRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonInsufficientMana) {
		t.Fatalf("cast_rejected=%v, want insufficient_mana", got)
	}
}

func TestCastRefusesOutOfRange(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 20, Z: 0}
	beforeMana := alice.mana
	beforeHP := bob.hp

	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: bob.id}, 1)

	if bob.hp != beforeHP || alice.mana != beforeMana {
		t.Fatalf("OOR cast mutated state hp=%d mana=%d", bob.hp, alice.mana)
	}
	got := pw.events(EvCastRejected)
	if len(got) != 1 || got[0]["reason"] != string(mnet.ReasonOutOfRange) {
		t.Fatalf("cast_rejected=%v, want out_of_range", got)
	}
}

func TestCastJSONOnlyDamageAndMana(t *testing.T) {
	pw := newProbeWorld(t)
	custom := `{
  "abilities":[{
    "id":"fireball","name":"Fireball","mana_cost":10,"cooldown_ticks":1,"range":8,
    "target":"hostile","effect":{"kind":"damage","amount":7},
    "ui":{"hotbar_slot":2,"color":"red"}
  },{
    "id":"heal","name":"Heal","mana_cost":5,"cooldown_ticks":1,"range":0,
    "target":"friendly","effect":{"kind":"heal","amount":3},
    "ui":{"hotbar_slot":1,"color":"green"}
  }]
}`
	pw.w.SetAbilities(mustParseAbilities(t, custom))
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 1, Z: 0}

	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: bob.id}, 1)

	if bob.hp != MaxHP-7 {
		t.Fatalf("custom damage: hp=%d, want %d", bob.hp, MaxHP-7)
	}
	if alice.mana != MaxMana-10 {
		t.Fatalf("custom mana: mana=%d, want %d", alice.mana, MaxMana-10)
	}
}

func TestCastIgnoresClientAuthoredDamage(t *testing.T) {
	// Wire Cast has no damage field. Decode drops unknown keys; this pins that
	// the effect amount comes from the catalog only.
	pw := newProbeWorld(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 1, Z: 0}

	msg, _, err := mnet.Decode([]byte(`{"cast":{"ability":"fireball","player":2,"damage":999}}`))
	if err != nil {
		t.Fatal(err)
	}
	cast, ok := msg.(mnet.Cast)
	if !ok {
		t.Fatalf("got %T", msg)
	}
	if cast.Ability != "fireball" || cast.Player != 2 {
		t.Fatalf("cast=%+v", cast)
	}
	pw.w.cast(alice, cast, 1)
	if bob.hp != MaxHP-40 {
		t.Fatalf("client damage leaked: hp=%d", bob.hp)
	}
}

func TestDecodeCastRequiresAbility(t *testing.T) {
	_, _, err := mnet.Decode([]byte(`{"cast":{"player":2}}`))
	rejection, ok := mnet.Rejection(err)
	if !ok || rejection.Reason != mnet.ReasonMissingField {
		t.Fatalf("err=%v, want missing_field", err)
	}
}

const sharedAbilitiesJSON = `{
  "abilities": [
    {
      "id": "heal",
      "name": "Heal",
      "mana_cost": 20,
      "cooldown_ticks": 10,
      "range": 0,
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

func mustParseAbilities(t *testing.T, raw string) *abilitydef.Catalog {
	t.Helper()
	cat, err := abilitydef.Parse([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	return cat
}
