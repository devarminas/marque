package weapondef

import (
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
	}
}

func TestMissingUnarmedFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"weapons":[{"id":"sword","attack_period_ticks":4}]}`))
	if err == nil {
		t.Fatal("expected missing unarmed error")
	}
}

func TestZeroPeriodFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"weapons":[{"id":"unarmed","attack_period_ticks":0}]}`))
	if err == nil {
		t.Fatal("expected zero period error")
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
		{"id":"unarmed","attack_period_ticks":4},
		{"id":"unarmed","attack_period_ticks":3}
	]}`))
	if err == nil {
		t.Fatal("expected duplicate id error")
	}
}
