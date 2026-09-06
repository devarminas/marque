package classdef

import (
	"path/filepath"
	"runtime"
	"testing"
)

func sharedPath(t *testing.T, rel string) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(rel))
}

func TestLoadSharedSets(t *testing.T) {
	cat, err := LoadSets(sharedPath(t, SetsRelPath))
	if err != nil {
		t.Fatalf("LoadSets: %v", err)
	}
	if cat.SetLen() != 5 {
		t.Fatalf("want 5 sets, got %d (%v)", cat.SetLen(), cat.SetIDs())
	}
	miner, ok := cat.GetSet("miner")
	if !ok {
		t.Fatal("missing miner set")
	}
	if miner.Name != "Miner" {
		t.Fatalf("miner name %q", miner.Name)
	}
	if miner.Slots["helmet"] != "prospector_helm" {
		t.Fatalf("miner helmet %q", miner.Slots["helmet"])
	}
	if miner.Slots["boots"] != "prospector_boots" {
		t.Fatalf("miner boots %q", miner.Slots["boots"])
	}
	if p, ok := miner.Tools["pickaxe"]; !ok || p.Handed != HandedOne {
		t.Fatalf("miner pickaxe missing or wrong handed: %+v", p)
	}
	lj, ok := cat.GetSet("lumberjack")
	if !ok {
		t.Fatal("missing lumberjack set")
	}
	if lj.Slots["chest"] != "forester_shirt" {
		t.Fatalf("lumberjack chest %q", lj.Slots["chest"])
	}
	if a, ok := lj.Tools["axe"]; !ok || a.Handed != HandedTwo {
		t.Fatalf("lumberjack axe missing or wrong handed: %+v", a)
	}
}

func TestLoadSharedSkills(t *testing.T) {
	cat, err := LoadSkills(sharedPath(t, SkillsRelPath))
	if err != nil {
		t.Fatalf("LoadSkills: %v", err)
	}
	if cat.SkillLen() != 5 {
		t.Fatalf("want 5 skills, got %d (%v)", cat.SkillLen(), cat.SkillIDs())
	}
	for _, id := range []string{"mining", "woodcutting", "combat", "magic", "ranged"} {
		if _, ok := cat.GetSkill(id); !ok {
			t.Fatalf("missing skill %q", id)
		}
	}
	mining, _ := cat.GetSkill("mining")
	if mining.MaxLevel != 99 {
		t.Fatalf("mining max_level %d, want 99", mining.MaxLevel)
	}
}

func TestMissingFilesFailClosed(t *testing.T) {
	if _, err := LoadSets(filepath.Join(t.TempDir(), "nope.json")); err == nil {
		t.Fatal("expected error for missing sets file")
	}
	if _, err := LoadSkills(filepath.Join(t.TempDir(), "nope.json")); err == nil {
		t.Fatal("expected error for missing skills file")
	}
}

func TestMalformedFailsClosed(t *testing.T) {
	bad := []byte(`{"sets":[`)
	if _, err := ParseSets(bad); err == nil {
		t.Fatal("expected malformed sets error")
	}
	if _, err := ParseSkills([]byte(`{"skills":[`)); err == nil {
		t.Fatal("expected malformed skills error")
	}
}

func TestEmptyTablesFailClosed(t *testing.T) {
	if _, err := ParseSets([]byte(`{"sets":[]}`)); err == nil {
		t.Fatal("expected empty sets error")
	}
	if _, err := ParseSkills([]byte(`{"skills":[]}`)); err == nil {
		t.Fatal("expected empty skills error")
	}
}

func TestDuplicateSetIDFailsClosed(t *testing.T) {
	_, err := ParseSets([]byte(`{
		"sets":[
			{"id":"miner","name":"Miner","slots":{"chest":"prospector_jacket"},"tools":{}},
			{"id":"miner","name":"Miner 2","slots":{"chest":"prospector_jacket"},"tools":{}}
		]
	}`))
	if err == nil {
		t.Fatal("expected duplicate set id error")
	}
}

func TestDuplicateSkillIDFailsClosed(t *testing.T) {
	_, err := ParseSkills([]byte(`{
		"skills":[
			{"id":"mining","name":"Mining","max_level":99},
			{"id":"mining","name":"Mining 2","max_level":99}
		]
	}`))
	if err == nil {
		t.Fatal("expected duplicate skill id error")
	}
}

func TestUnknownHandedFailsClosed(t *testing.T) {
	_, err := ParseSets([]byte(`{
		"sets":[
			{"id":"miner","name":"Miner","slots":{},"tools":{"pickaxe":{"handed":"three"}}}
		]
	}`))
	if err == nil {
		t.Fatal("expected unknown handed error")
	}
}

func TestResolveSetsPathFindsShared(t *testing.T) {
	path := sharedPath(t, SetsRelPath)
	repo := filepath.Dir(filepath.Dir(path))
	t.Chdir(filepath.Join(repo, "server"))
	got, err := ResolveSetsPath()
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
		t.Fatalf("ResolveSetsPath=%q want %q", gotAbs, want)
	}
}

func TestResolveSkillsPathFindsShared(t *testing.T) {
	path := sharedPath(t, SkillsRelPath)
	repo := filepath.Dir(filepath.Dir(path))
	t.Chdir(filepath.Join(repo, "server"))
	got, err := ResolveSkillsPath()
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
		t.Fatalf("ResolveSkillsPath=%q want %q", gotAbs, want)
	}
}