package weapondef

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func sharedWeaponsPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(RelPath))
}

func TestLoadSharedWeapons(t *testing.T) {
	path := sharedWeaponsPath(t)
	cat, err := Load(path)
	if err != nil {
		t.Fatalf("Load(%s): %v", path, err)
	}
	for _, id := range []string{Unarmed, Sword, Staff, Bow, ImpClaw} {
		w, ok := cat.Get(id)
		if !ok {
			t.Fatalf("missing %q", id)
		}
		if w.AttackPeriodTicks < 1 {
			t.Fatalf("%q period=%d", id, w.AttackPeriodTicks)
		}
		if w.DamageMin < 1 || w.DamageMax < w.DamageMin {
			t.Fatalf("%q damage=[%d,%d]", id, w.DamageMin, w.DamageMax)
		}
	}
}

func TestSharedWeaponsAreDistinctAndImpClawIsWeaker(t *testing.T) {
	cat, err := Load(sharedWeaponsPath(t))
	if err != nil {
		t.Fatal(err)
	}
	claw, ok := cat.Get(ImpClaw)
	if !ok {
		t.Fatal("missing imp_claw")
	}
	sword, ok := cat.Get(Sword)
	if !ok {
		t.Fatal("missing sword")
	}
	if claw.AttackPeriodTicks <= sword.AttackPeriodTicks {
		t.Fatalf("imp_claw period %d is not slower than sword %d", claw.AttackPeriodTicks, sword.AttackPeriodTicks)
	}
	clawAvg := float64(claw.DamageMin+claw.DamageMax) / 2
	swordAvg := float64(sword.DamageMin+sword.DamageMax) / 2
	if clawAvg >= swordAvg {
		t.Fatalf("imp_claw avg damage %.1f is not weaker than sword %.1f", clawAvg, swordAvg)
	}
	seen := map[string]string{}
	for _, id := range []string{Unarmed, Sword, Staff, Bow, ImpClaw} {
		w, ok := cat.Get(id)
		if !ok {
			t.Fatalf("missing %q", id)
		}
		key := fmt.Sprintf("%d:%d:%d", w.AttackPeriodTicks, w.DamageMin, w.DamageMax)
		if other, dup := seen[key]; dup {
			t.Fatalf("%q and %q share period+damage %s", id, other, key)
		}
		seen[key] = id
	}
}

func TestMissingUnarmedFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"weapons":[{"id":"sword","attack_period_ticks":4,"damage_min":1,"damage_max":2}]}`))
	if err == nil {
		t.Fatal("expected missing unarmed error")
	}
}

func TestZeroPeriodFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"weapons":[{"id":"unarmed","attack_period_ticks":0,"damage_min":1,"damage_max":2}]}`))
	if err == nil {
		t.Fatal("expected zero period error")
	}
}

func TestMissingDamageFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"weapons":[{"id":"unarmed","attack_period_ticks":4}]}`))
	if err == nil {
		t.Fatal("expected missing damage_min/max error")
	}
}

func TestInvertedDamageFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"weapons":[{"id":"unarmed","attack_period_ticks":4,"damage_min":5,"damage_max":2}]}`))
	if err == nil {
		t.Fatal("expected inverted damage range error")
	}
}

func TestMissingFileFailsClosed(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "nope.json"))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestMalformedFailsClosed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.json")
	if err := os.WriteFile(path, []byte(`{"weapons":[`), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected malformed error")
	}
}

func TestEmptyWeaponsFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"weapons":[]}`))
	if err == nil {
		t.Fatal("expected empty weapons error")
	}
}

func TestDuplicateIDFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"weapons":[
		{"id":"unarmed","attack_period_ticks":4,"damage_min":1,"damage_max":2},
		{"id":"unarmed","attack_period_ticks":3,"damage_min":1,"damage_max":2}
	]}`))
	if err == nil {
		t.Fatal("expected duplicate id error")
	}
}
