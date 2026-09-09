package questdef

import (
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"testing"

	"github.com/devarminas/marque/server/internal/classdef"
)

func sharedQuestsPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(RelPath))
}

func sharedSetsPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(classdef.SetsRelPath))
}

func mustLoadSets(t *testing.T) *classdef.Catalog {
	t.Helper()
	cat, err := classdef.LoadSets(sharedSetsPath(t))
	if err != nil {
		t.Fatalf("LoadSets: %v", err)
	}
	return cat
}

func TestLoadSharedBringAStick(t *testing.T) {
	sets := mustLoadSets(t)
	cat, err := Load(sharedQuestsPath(t), sets)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cat.Len() != 1 {
		t.Fatalf("want 1 quest, got %d (%v)", cat.Len(), cat.IDs())
	}
	q, ok := cat.Get("bring_a_stick")
	if !ok {
		t.Fatal("missing bring_a_stick")
	}
	if q.TalkNPC != "quest_giver" {
		t.Fatalf("talk_npc=%q", q.TalkNPC)
	}
	if q.Deliver.Kind != "sticks" || q.Deliver.Qty != 1 {
		t.Fatalf("deliver=%+v", q.Deliver)
	}
	if q.RewardSet != "miner" {
		t.Fatalf("reward_set=%q", q.RewardSet)
	}
	want := []string{
		"prospector_jacket",
		"prospector_boots",
		"prospector_helm",
		"prospector_legs",
		"pickaxe",
	}
	if !slices.Equal(q.RewardKinds, want) {
		t.Fatalf("RewardKinds=%v want %v", q.RewardKinds, want)
	}
}

func TestMissingFileFailsClosed(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "nope.json"), mustLoadSets(t))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestMalformedFailsClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.json")
	if err := os.WriteFile(path, []byte(`{"quests":[`), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Load(path, mustLoadSets(t))
	if err == nil {
		t.Fatal("expected malformed error")
	}
}

func TestEmptyQuestsFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"quests":[]}`), mustLoadSets(t))
	if err == nil {
		t.Fatal("expected empty quests error")
	}
}

func TestNilSetsFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{
		"quests":[{
			"id":"x","name":"X","talk_npc":"n",
			"deliver":{"kind":"sticks","qty":1},"reward_set":"miner"
		}]
	}`), nil)
	if err == nil {
		t.Fatal("expected nil sets error")
	}
}

func TestUnknownRewardSetFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{
		"quests":[{
			"id":"x","name":"X","talk_npc":"n",
			"deliver":{"kind":"sticks","qty":1},"reward_set":"no_such_set"
		}]
	}`), mustLoadSets(t))
	if err == nil {
		t.Fatal("expected unknown reward_set error")
	}
}

func TestMissingDeliverKindFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{
		"quests":[{
			"id":"x","name":"X","talk_npc":"n",
			"deliver":{"kind":"","qty":1},"reward_set":"miner"
		}]
	}`), mustLoadSets(t))
	if err == nil {
		t.Fatal("expected missing deliver.kind error")
	}
}

func TestDeliverQtyZeroFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{
		"quests":[{
			"id":"x","name":"X","talk_npc":"n",
			"deliver":{"kind":"sticks","qty":0},"reward_set":"miner"
		}]
	}`), mustLoadSets(t))
	if err == nil {
		t.Fatal("expected deliver.qty error")
	}
}

func TestDuplicateIDFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{
		"quests":[
			{"id":"x","name":"X","talk_npc":"n","deliver":{"kind":"sticks","qty":1},"reward_set":"miner"},
			{"id":"x","name":"Y","talk_npc":"n","deliver":{"kind":"sticks","qty":1},"reward_set":"miner"}
		]
	}`), mustLoadSets(t))
	if err == nil {
		t.Fatal("expected duplicate id error")
	}
}

func TestEmptyRewardSetFailsClosed(t *testing.T) {
	emptySets, err := classdef.ParseSets([]byte(`{
		"sets":[{
			"id":"hollow","name":"Hollow","slots":{},"tools":{}
		}]
	}`))
	if err != nil {
		t.Fatalf("ParseSets hollow: %v", err)
	}
	_, err = Parse([]byte(`{
		"quests":[{
			"id":"x","name":"X","talk_npc":"n",
			"deliver":{"kind":"sticks","qty":1},"reward_set":"hollow"
		}]
	}`), emptySets)
	if err == nil {
		t.Fatal("expected empty reward kinds error")
	}
}

func TestResolvePathFindsShared(t *testing.T) {
	path := sharedQuestsPath(t)
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
