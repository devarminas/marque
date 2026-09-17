package npcdef

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func sharedArchetypesPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(RelPath))
}

func TestLoadSharedImpArchetype(t *testing.T) {
	cat, err := Load(sharedArchetypesPath(t))
	if err != nil {
		t.Fatal(err)
	}
	imp, ok := cat.Get(Imp)
	if !ok {
		t.Fatal("missing imp")
	}
	if imp.MaxHP != 50 || imp.WeaponID != "imp_claw" {
		t.Fatalf("imp hp/weapon: %+v", imp)
	}
	if imp.Threat != 8 || imp.Leash != 16 || imp.Wander != 3 {
		t.Fatalf("imp ranges: %+v", imp)
	}
	if imp.SkillID() != "fireball" {
		t.Fatalf("imp skill=%q", imp.SkillID())
	}
	if imp.IdleMinTicks != 50 || imp.IdleMaxTicks != 150 {
		t.Fatalf("imp idle: %+v", imp)
	}
	if imp.STR != 10 || imp.DEX != 10 || imp.CON != 5 || imp.INT != 10 {
		t.Fatalf("imp attrs: %+v", imp)
	}
}

func TestResolvePathFindsShared(t *testing.T) {
	got, err := ResolvePath()
	if err != nil {
		t.Fatal(err)
	}
	want := sharedArchetypesPath(t)
	gotAbs, err := filepath.Abs(got)
	if err != nil {
		t.Fatal(err)
	}
	wantAbs, err := filepath.Abs(want)
	if err != nil {
		t.Fatal(err)
	}
	if gotAbs != wantAbs {
		t.Fatalf("ResolvePath=%q want %q", gotAbs, wantAbs)
	}
}

func TestMissingImpFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"archetypes":[{
		"id":"goblin","max_hp":50,"weapon_id":"imp_claw","threat":8,"leash":16,"wander":3,
		"skills":["fireball"],"idle_min_ticks":50,"idle_max_ticks":150,
		"str":10,"dex":10,"con":5,"int":10
	}]}`))
	if err == nil {
		t.Fatal("expected missing imp error")
	}
}

func TestMissingRequiredFieldsFailClosed(t *testing.T) {
	cases := []string{
		`{"archetypes":[{"id":"imp","weapon_id":"imp_claw","threat":8,"leash":16,"wander":3,"skills":["fireball"],"idle_min_ticks":50,"idle_max_ticks":150,"str":10,"dex":10,"con":5,"int":10}]}`,
		`{"archetypes":[{"id":"imp","max_hp":50,"threat":8,"leash":16,"wander":3,"skills":["fireball"],"idle_min_ticks":50,"idle_max_ticks":150,"str":10,"dex":10,"con":5,"int":10}]}`,
		`{"archetypes":[{"id":"imp","max_hp":50,"weapon_id":"imp_claw","leash":16,"wander":3,"skills":["fireball"],"idle_min_ticks":50,"idle_max_ticks":150,"str":10,"dex":10,"con":5,"int":10}]}`,
		`{"archetypes":[{"id":"imp","max_hp":50,"weapon_id":"imp_claw","threat":8,"leash":16,"wander":3,"idle_min_ticks":50,"idle_max_ticks":150,"str":10,"dex":10,"con":5,"int":10}]}`,
		`{"archetypes":[{"id":"imp","max_hp":40,"weapon_id":"imp_claw","threat":8,"leash":16,"wander":3,"skills":["fireball"],"idle_min_ticks":50,"idle_max_ticks":150,"str":10,"dex":10,"con":5,"int":10}]}`,
		`{"archetypes":[{"id":"imp","max_hp":50,"weapon_id":"imp_claw","threat":8,"leash":16,"wander":16,"skills":["fireball"],"idle_min_ticks":50,"idle_max_ticks":150,"str":10,"dex":10,"con":5,"int":10}]}`,
		`{"archetypes":[{"id":"imp","max_hp":50,"weapon_id":"imp_claw","threat":8,"leash":16,"wander":3,"skills":["fireball"],"idle_min_ticks":150,"idle_max_ticks":50,"str":10,"dex":10,"con":5,"int":10}]}`,
	}
	for _, raw := range cases {
		if _, err := Parse([]byte(raw)); err == nil {
			t.Fatalf("expected fail closed for %s", raw)
		}
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
	if err := os.WriteFile(path, []byte(`{"archetypes":[`), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected malformed error")
	}
}

func TestEmptyArchetypesFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"archetypes":[]}`))
	if err == nil {
		t.Fatal("expected empty archetypes error")
	}
}
