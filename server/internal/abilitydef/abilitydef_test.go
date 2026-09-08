package abilitydef

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func sharedAbilitiesPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(RelPath))
}

func TestLoadSharedStarterAbilities(t *testing.T) {
	path := sharedAbilitiesPath(t)
	cat, err := Load(path)
	if err != nil {
		t.Fatalf("Load(%s): %v", path, err)
	}
	if cat.Len() != 2 {
		t.Fatalf("want 2 abilities, got %d (%v)", cat.Len(), cat.IDs())
	}
	heal, ok := cat.Get("heal")
	if !ok {
		t.Fatal("missing heal")
	}
	if heal.Target != TargetFriendly || heal.Effect.Kind != EffectHeal || heal.UI.Color != "green" {
		t.Fatalf("heal shape: %+v", heal)
	}
	if heal.ManaCost <= 0 || heal.Range < 0 {
		t.Fatalf("heal mana/range: %+v", heal)
	}
	fb, ok := cat.Get("fireball")
	if !ok {
		t.Fatal("missing fireball")
	}
	if fb.Target != TargetHostile || fb.Effect.Kind != EffectDamage || fb.UI.Color != "red" {
		t.Fatalf("fireball shape: %+v", fb)
	}
	if fb.ManaCost <= 0 || fb.Range <= 0 {
		t.Fatalf("fireball mana/range: %+v", fb)
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
	if err := os.WriteFile(path, []byte(`{"abilities":[`), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected malformed error")
	}
}

func TestEmptyAbilitiesFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"abilities":[]}`))
	if err == nil {
		t.Fatal("expected empty abilities error")
	}
}

func TestZeroManaCostFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{
		"abilities":[{
			"id":"x","name":"X","mana_cost":0,"cooldown_ticks":0,"range":0,
			"target":"self","effect":{"kind":"heal","amount":1},
			"ui":{"hotbar_slot":1,"color":"green"}
		}]
	}`))
	if err == nil {
		t.Fatal("expected zero mana_cost error")
	}
}

func TestSubHalfManaCostFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{
		"abilities":[{
			"id":"x","name":"X","mana_cost":0.4,"cooldown_ticks":0,"range":0,
			"target":"self","effect":{"kind":"heal","amount":1},
			"ui":{"hotbar_slot":1,"color":"green"}
		}]
	}`))
	if err == nil {
		t.Fatal("expected sub-0.5 mana_cost error")
	}
}

func TestUnknownEffectFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{
		"abilities":[{
			"id":"x","name":"X","mana_cost":1,"cooldown_ticks":0,"range":0,
			"target":"self","effect":{"kind":"explode","amount":1},
			"ui":{"hotbar_slot":1,"color":"blue"}
		}]
	}`))
	if err == nil {
		t.Fatal("expected unknown effect error")
	}
}

func TestResolvePathFindsShared(t *testing.T) {
	path := sharedAbilitiesPath(t)
	repo := filepath.Dir(filepath.Dir(path))
	t.Chdir(filepath.Join(repo, "server"))
	got, err := ResolvePath()
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.Abs(path)
	if err != nil {
		t.Fatal(err)
	}
	gotAbs, err := filepath.Abs(got)
	if err != nil {
		t.Fatal(err)
	}
	if gotAbs != want {
		t.Fatalf("ResolvePath=%q want %q", gotAbs, want)
	}
}
