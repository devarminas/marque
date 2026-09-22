package game

import (
	"testing"

	mrand "math/rand/v2"

	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/weapondef"
)

func TestDefaultPlayerAttrsMatchLegacyCaps(t *testing.T) {
	a := defaultPlayerAttrs()
	if a.maxHP() != MaxHP {
		t.Fatalf("player maxHP=%d, want %d", a.maxHP(), MaxHP)
	}
	if a.maxMana() != MaxMana {
		t.Fatalf("player maxMana=%d, want %d", a.maxMana(), MaxMana)
	}
	if a.AP() != 0 || a.SP() != 0 || a.Armor() != 0 || a.CritChance() != 0 {
		t.Fatalf("baseline derived not zero: AP=%d SP=%d Armor=%d Crit=%d", a.AP(), a.SP(), a.Armor(), a.CritChance())
	}
}

func TestSharedImpArchetypeMatchesCONMaxHP(t *testing.T) {
	a := attrsFromArchetype(loadSharedImp(t))
	if a.maxHP() != loadSharedImp(t).MaxHP {
		t.Fatalf("imp maxHP=%d, want %d", a.maxHP(), loadSharedImp(t).MaxHP)
	}
	if a.CON != 5 || a.maxHP() != 50 {
		t.Fatalf("imp CON/HP=%d/%d, want 5/50", a.CON, a.maxHP())
	}
}

func TestAttrsDerivedFormulas(t *testing.T) {
	a := attributes{STR: 12, DEX: 14, CON: 12, INT: 8}
	if a.maxHP() != 120 {
		t.Fatalf("maxHP=%d, want 120", a.maxHP())
	}
	if a.maxMana() != 80 {
		t.Fatalf("maxMana=%d, want 80", a.maxMana())
	}
	if a.AP() != 1 {
		t.Fatalf("AP=%d, want 1", a.AP())
	}
	if a.SP() != -1 {
		t.Fatalf("SP=%d, want -1", a.SP())
	}
	if a.Armor() != 2 {
		t.Fatalf("Armor=%d, want 2", a.Armor())
	}
	if a.CritChance() != 4 {
		t.Fatalf("Crit=%d, want 4", a.CritChance())
	}
}

func TestChangingCONChangesPlayerMaxHP(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	if alice.hp != MaxHP || alice.attrs.maxHP() != MaxHP {
		t.Fatalf("hp=%d max=%d", alice.hp, alice.attrs.maxHP())
	}
	alice.attrs.CON = 12
	if alice.attrs.maxHP() != 120 {
		t.Fatalf("maxHP=%d after CON 12", alice.attrs.maxHP())
	}
}

func TestWhiteDamageAddsAP(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetWeapons(parseWeapons(t, `{"weapons":[
		{"id":"unarmed","attack_period_ticks":8,"damage_min":3,"damage_max":3},
		{"id":"sword","attack_period_ticks":8,"damage_min":8,"damage_max":8},
		{"id":"imp_claw","attack_period_ticks":8,"damage_min":2,"damage_max":2}
	]}`))
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	alice.pos = hostile.pos
	alice.attrs.STR = 12
	if alice.attrs.AP() != 1 {
		t.Fatalf("AP=%d, want 1", alice.attrs.AP())
	}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 1)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	got := DummyMaxHP - hostile.hp
	if got != 9 {
		t.Fatalf("white with AP 1 = %d, want 8+1", got)
	}
}

func TestWhiteDamageSubtractsArmorFloorOne(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetWeapons(parseWeapons(t, `{"weapons":[
		{"id":"unarmed","attack_period_ticks":8,"damage_min":3,"damage_max":3},
		{"id":"sword","attack_period_ticks":8,"damage_min":8,"damage_max":8},
		{"id":"imp_claw","attack_period_ticks":8,"damage_min":2,"damage_max":2}
	]}`))
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	hostile.attrs.DEX = 14
	alice.pos = hostile.pos
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 1)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	got := DummyMaxHP - hostile.hp
	if got != 6 {
		t.Fatalf("white vs armor 2 = %d, want 8-2", got)
	}

	hostile.hp = DummyMaxHP
	hostile.attrs.DEX = 30
	alice.attackProgress = 0
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	got = DummyMaxHP - hostile.hp
	if got != 1 {
		t.Fatalf("armor past the roll must floor at 1, got %d", got)
	}
}

func TestWhiteCritDoublesBeforeArmor(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.rng = mrand.New(mrand.NewPCG(1, 2))
	pw.w.SetWeapons(parseWeapons(t, `{"weapons":[
		{"id":"unarmed","attack_period_ticks":8,"damage_min":3,"damage_max":3},
		{"id":"sword","attack_period_ticks":8,"damage_min":8,"damage_max":8},
		{"id":"imp_claw","attack_period_ticks":8,"damage_min":2,"damage_max":2}
	]}`))
	pw.w.SetWhiteMissPct(0)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	alice.pos = hostile.pos
	alice.attrs.DEX = AttrBaseline + 100
	if alice.attrs.CritChance() != 100 {
		t.Fatalf("crit=%d, want 100", alice.attrs.CritChance())
	}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 1)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	got := DummyMaxHP - hostile.hp
	if got != 16 {
		t.Fatalf("crit white = %d, want 8*2", got)
	}
}

func TestSpellDamageAddsSP(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("mage")
	bob := pw.joinBare()
	bob.pos = Point{X: 3, Z: 0}
	alice.attrs.INT = 12
	if alice.attrs.SP() != 1 {
		t.Fatalf("SP=%d, want 1", alice.attrs.SP())
	}
	before := bob.hp
	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: bob.id}, 1)
	pw.w.stepNForTest(alice.castTotal)
	if bob.hp != before-23 {
		t.Fatalf("fireball+SP hp=%d, want %d", bob.hp, before-23)
	}
}

func TestSeededImpUsesCONForMaxHP(t *testing.T) {
	pw := newProbeWorld(t)
	if err := pw.w.seedNPC(KindImp, FactionHostile, 5, 5, pw.impArch().MaxHP); err != nil {
		t.Fatal(err)
	}
	imp := pw.w.npcByKind(KindImp)
	want := attrsFromArchetype(pw.impArch())
	if imp.attrs != want {
		t.Fatalf("imp attrs=%+v, want %+v", imp.attrs, want)
	}
	if imp.maxHP != pw.impArch().MaxHP || imp.hp != pw.impArch().MaxHP {
		t.Fatalf("imp hp=%d/%d, want %d from CON 5", imp.hp, imp.maxHP, pw.impArch().MaxHP)
	}
}

func TestRollWhiteUsesWeaponRangeAndAP(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetWeapons(parseWeapons(t, `{"weapons":[
		{"id":"unarmed","attack_period_ticks":8,"damage_min":3,"damage_max":3},
		{"id":"sword","attack_period_ticks":8,"damage_min":8,"damage_max":12},
		{"id":"imp_claw","attack_period_ticks":8,"damage_min":2,"damage_max":2}
	]}`))
	atk := attributes{STR: 12, DEX: AttrBaseline, CON: AttrBaseline, INT: AttrBaseline}
	def := defaultPlayerAttrs()
	for range 20 {
		d := pw.w.rollWhiteDamage(weapondef.Sword, atk.AP(), atk.CritChance(), def.Armor()).damage
		if d < 9 || d > 13 {
			t.Fatalf("sword+AP1=%d outside [9,13]", d)
		}
	}
}

func TestWhiteZeroMissKnobKeepsSeededDrawSequence(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.SetWeapons(parseWeapons(t, `{"weapons":[
		{"id":"unarmed","attack_period_ticks":8,"damage_min":3,"damage_max":3},
		{"id":"sword","attack_period_ticks":8,"damage_min":8,"damage_max":12},
		{"id":"imp_claw","attack_period_ticks":8,"damage_min":2,"damage_max":2}
	]}`))
	pw.w.SetWhiteMissPct(0)
	pw.w.rng = mrand.New(mrand.NewPCG(11, 22))
	baseline := mrand.New(mrand.NewPCG(11, 22))
	wantDamage := 8 + baseline.IntN(5)
	_ = baseline.IntN(100)
	hit := pw.w.rollWhiteDamage(weapondef.Sword, 0, 100, 0)
	if hit.miss || !hit.crit || hit.damage != wantDamage*2 {
		t.Fatalf("zero miss roll=%+v, want crit damage=%d", hit, wantDamage*2)
	}
	if got, want := pw.w.rng.Uint64(), baseline.Uint64(); got != want {
		t.Fatalf("next seeded draw=%d, want %d after exactly two draws", got, want)
	}
}

func TestWhiteMissConsumesOneDraw(t *testing.T) {
	pw := newProbeWorld(t)
	pw.w.rng = mrand.New(mrand.NewPCG(11, 22))
	pw.w.SetWhiteMissPct(100)
	baseline := mrand.New(mrand.NewPCG(11, 22))
	_ = baseline.IntN(100)
	if hit := pw.w.rollWhiteDamage(weapondef.Sword, 0, 100, 100); hit != (whiteRoll{miss: true}) {
		t.Fatalf("miss roll=%+v, want only miss", hit)
	}
	if got, want := pw.w.rng.Uint64(), baseline.Uint64(); got != want {
		t.Fatalf("next seeded draw=%d, want %d after exactly one draw", got, want)
	}
}

func TestImpWhiteDamageAddsAP(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetWeapons(parseWeapons(t, `{"weapons":[
		{"id":"unarmed","attack_period_ticks":8,"damage_min":3,"damage_max":3},
		{"id":"sword","attack_period_ticks":8,"damage_min":8,"damage_max":8},
		{"id":"imp_claw","attack_period_ticks":8,"damage_min":2,"damage_max":2}
	]}`))
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	alice.pos = imp.pos
	imp.attrs.STR = 12
	if imp.attrs.AP() != 1 {
		t.Fatalf("imp AP=%d, want 1", imp.attrs.AP())
	}
	imp.phase = phaseCombat
	imp.combatBeat = combatSwing
	imp.attackTarget = alice.id
	imp.remaining = nil
	before := alice.hp
	for range pw.npcPeriod(imp) {
		pw.w.step()
	}
	if alice.hp != before-3 {
		t.Fatalf("imp white with AP 1 = %d, want 2+1", before-alice.hp)
	}
}

func TestImpSpellDamageAddsSP(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("knight")
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.pos = Point{X: 0, Z: 0}
	imp.home = imp.pos
	alice.pos = Point{X: 4, Z: 0}
	imp.attrs.INT = 12
	if imp.attrs.SP() != 1 {
		t.Fatalf("imp SP=%d, want 1", imp.attrs.SP())
	}
	imp.phase = phaseCombat
	imp.combatBeat = combatThink
	imp.attackTarget = alice.id
	imp.thinkProgress = 0
	imp.thinkCount = ImpCastEvery - 1
	imp.remaining = nil
	before := alice.hp
	for range ImpThinkTicks {
		pw.w.step()
	}
	if !imp.casting() {
		t.Fatal("expected fireball cast")
	}
	pw.w.stepNForTest(imp.castTotal)
	if alice.hp != before-23 {
		t.Fatalf("imp fireball+SP hp=%d, want %d", alice.hp, before-23)
	}
}

func TestHealDoesNotAddSP(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	pw.w.SetWhiteMissPct(100)
	alice := pw.joinWithClass("mage")
	alice.hp = 50
	alice.attrs.INT = 12
	pw.w.cast(alice, mnet.Cast{Ability: "heal", Player: alice.id}, 1)
	if alice.hp != 75 {
		t.Fatalf("heal+SP hp=%d, want 75 (heal stays 25, no SP)", alice.hp)
	}
}
