package classdef

import (
	"path/filepath"
	"runtime"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
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
	if miner.Slots["feet"] != "prospector_boots" {
		t.Fatalf("miner feet %q", miner.Slots["feet"])
	}
	if p, ok := miner.Tools["pickaxe"]; !ok || p.Handed != HandedOne || p.Slot != "right hand" {
		t.Fatalf("miner pickaxe missing or wrong: %+v", p)
	}
	lj, ok := cat.GetSet("lumberjack")
	if !ok {
		t.Fatal("missing lumberjack set")
	}
	if lj.Slots["chest"] != "forester_shirt" {
		t.Fatalf("lumberjack chest %q", lj.Slots["chest"])
	}
	if a, ok := lj.Tools["lumberjack_axe"]; !ok || a.Handed != HandedTwo {
		t.Fatalf("lumberjack_axe missing or wrong handed: %+v", a)
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

func TestUnknownSlotKeyFailsClosed(t *testing.T) {
	raw := []byte(`{"sets":[{"id":"x","name":"X","slots":{"helmett":"helm"},"tools":{}}]}`)
	if _, err := ParseSets(raw); err == nil {
		t.Fatal("expected unknown worn slot error")
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

func TestLoadSharedClasses(t *testing.T) {
	cat, err := LoadClasses(sharedPath(t, ClassesRelPath))
	if err != nil {
		t.Fatalf("LoadClasses: %v", err)
	}
	if cat.ClassLen() != 5 {
		t.Fatalf("want 5 classes, got %d (%v)", cat.ClassLen(), cat.ClassIDs())
	}
	for _, id := range []string{"knight", "mage", "archer", "miner", "lumberjack"} {
		if _, ok := cat.GetClass(id); !ok {
			t.Fatalf("missing class %q", id)
		}
	}
	knight, _ := cat.GetClass("knight")
	if knight.Skill != "combat" {
		t.Fatalf("knight skill %q, want combat", knight.Skill)
	}
	if knight.Requires["right hand"] != "sword" || knight.Requires["left hand"] != "shield" {
		t.Fatalf("knight requires %v, want sword+shield in the hands", knight.Requires)
	}
}

func fullWorn(t *testing.T, cat *Catalog, id string) map[string]string {
	t.Helper()
	cl, ok := cat.GetClass(id)
	if !ok {
		t.Fatalf("no class %q", id)
	}
	worn := make(map[string]string, len(cl.Requires))
	for slot, kind := range cl.Requires {
		worn[slot] = kind
	}
	return worn
}

func TestClassOfFullSetIsActive(t *testing.T) {
	cat, err := LoadAll()
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	for _, id := range []string{"knight", "mage", "archer", "miner", "lumberjack"} {
		res := ClassOf(fullWorn(t, cat, id), cat)
		if res.Class == nil {
			t.Fatalf("%s: full set did not activate", id)
		}
		if res.Class.ID != id {
			t.Fatalf("%s: activated %q", id, res.Class.ID)
		}
		if len(res.Missing) != 0 {
			t.Fatalf("%s: full set reports missing %v", id, res.Missing)
		}
	}
}

func TestClassOfPartialIsInactiveNamesMissing(t *testing.T) {
	cat, err := LoadAll()
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	knight, ok := cat.GetClass("knight")
	if !ok {
		t.Fatal("missing knight class")
	}
	_ = knight
	worn := fullWorn(t, cat, "knight")
	delete(worn, "right hand")

	res := ClassOf(worn, cat)
	if res.Class != nil {
		t.Fatalf("knight without its sword is active as %q, want inactive", res.Class.ID)
	}
	if res.Missing["right hand"] != "sword" {
		t.Fatalf("missing %v, want the right hand to need a sword", res.Missing)
	}
	if len(res.Missing) != 1 {
		t.Fatalf("missing %v, want exactly the sword", res.Missing)
	}
	if res0 := ClassOf(nil, cat); res0.Class != nil {
		t.Fatalf("empty worn set activated %q", res0.Class.ID)
	}
}

func TestClassOfOnlyOneAtATime(t *testing.T) {
	cat, err := LoadAll()
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	worn := fullWorn(t, cat, "knight")
	delete(worn, "right hand")
	worn["feet"] = "prospector_boots"
	res := ClassOf(worn, cat)
	if res.Class != nil {
		t.Fatalf("a mixed set activated %q, want no class at once", res.Class.ID)
	}
	lj := fullWorn(t, cat, "lumberjack")
	lj["feet"] = "prospector_boots"
	res2 := ClassOf(lj, cat)
	if res2.Class == nil || res2.Class.ID != "lumberjack" {
		t.Fatalf("full lumberjack with spare boots resolved to %+v, want lumberjack", res2.Class)
	}
}

func TestSkillLevelIsAPureFunctionOfXP(t *testing.T) {
	cat, err := LoadAll()
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	mining, _ := cat.GetSkill("mining")
	if mining.MaxLevel != 99 {
		t.Fatalf("mining max_level %d, want 99", mining.MaxLevel)
	}
	cases := []struct {
		xp   int64
		want int
	}{
		{0, 1},
		{XPPerLevel - 1, 1},
		{XPPerLevel, 2},
		{2 * XPPerLevel, 3},
		{int64(mining.MaxLevel-1) * XPPerLevel, mining.MaxLevel},
		{int64(mining.MaxLevel) * XPPerLevel, mining.MaxLevel},
		{10 * XPPerLevel * XPPerLevel, mining.MaxLevel},
	}
	for _, c := range cases {
		if got := SkillLevel(c.xp, mining.MaxLevel); got != c.want {
			t.Fatalf("SkillLevel(%d, %d)=%d, want %d", c.xp, mining.MaxLevel, got, c.want)
		}
	}
	prev := 0
	for xp := int64(0); xp < 5*XPPerLevel; xp += 17 {
		if lv := SkillLevel(xp, mining.MaxLevel); lv < prev {
			t.Fatalf("SkillLevel(%d)=%d fell below %d", xp, lv, prev)
		} else {
			prev = lv
		}
	}
	if got := cat.LevelFor("mining", XPPerLevel); got != 2 {
		t.Fatalf("LevelFor(mining, %d)=%d, want 2", XPPerLevel, got)
	}
	if got := cat.LevelFor("no_such_skill", XPPerLevel); got != 2 {
		t.Fatalf("unknown skill LevelFor=%d, want the shared default", got)
	}
}

func TestWireMissingSplitsSlotsAndTools(t *testing.T) {
	slots, tools := WireMissing(map[string]string{
		"helmet":     "plate_helm",
		"right hand": "sword",
	}, []mnet.EquipSlot{"helmet", "left hand", "chest", "right hand", "feet", "trousers"})
	if len(slots) != 2 || len(tools) != 0 {
		t.Fatalf("WireMissing(slots+tool-slot)=%v,%v, want both in Slots", slots, tools)
	}
	slots, tools = WireMissing(map[string]string{
		"helmet": "plate_helm",
		"feet":   "prospector_boots",
	}, []mnet.EquipSlot{"helmet", "left hand", "chest", "right hand", "feet", "trousers"})
	if len(slots) != 2 || len(tools) != 0 {
		t.Fatalf("WireMissing(slots)=%v,%v, want two slots and no tools", slots, tools)
	}
	if slots[0].Slot != "helmet" || slots[1].Slot != "feet" {
		t.Fatalf("WireMissing ordered %v, want helmet then feet by WornSlots order", slots)
	}
	if s, tt := WireMissing(nil, nil); len(s) != 0 || len(tt) != 0 {
		t.Fatalf("WireMissing(nil)=%v,%v, want empty slices", s, tt)
	}
}

func TestWearablesFromSharedCatalog(t *testing.T) {
	cat, err := LoadAll()
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	wearables, err := cat.Wearables()
	if err != nil {
		t.Fatalf("Wearables: %v", err)
	}
	if got := wearables["prospector_boots"]; len(got) != 1 || got[0] != "feet" {
		t.Fatalf("prospector_boots → %v, want [feet]", got)
	}
	if got := wearables["lumberjack_axe"]; len(got) != 2 || got[0] != "left hand" || got[1] != "right hand" {
		t.Fatalf("lumberjack_axe → %v, want both hands", got)
	}
	if got := wearables["sword"]; len(got) != 1 || got[0] != "right hand" {
		t.Fatalf("sword → %v, want [right hand]", got)
	}
	if got := wearables["shield"]; len(got) != 1 || got[0] != "left hand" {
		t.Fatalf("shield → %v, want [left hand]", got)
	}
	if _, ok := wearables["axe"]; ok {
		t.Fatal("prototype axe must not be wearable")
	}
}

func TestWearablesRejectsMissingClassRequire(t *testing.T) {
	cat, err := ParseSets([]byte(`{
		"sets":[{
			"id":"miner","name":"Miner",
			"slots":{"helmet":"prospector_helm"},
			"tools":{"pickaxe":{"handed":"one","slot":"right hand"}}
		}]
	}`))
	if err != nil {
		t.Fatalf("ParseSets: %v", err)
	}
	classes, err := ParseClasses([]byte(`{
		"classes":[{
			"id":"miner","name":"Miner","skill":"mining",
			"requires":{"helmet":"prospector_helm","right hand":"pickaxe","feet":"prospector_boots"}
		}]
	}`))
	if err != nil {
		t.Fatalf("ParseClasses: %v", err)
	}
	cat.classes = classes.classes
	if _, err := cat.Wearables(); err == nil {
		t.Fatal("expected missing require kind error")
	}
}

func TestOneHandedToolRequiresSlot(t *testing.T) {
	_, err := ParseSets([]byte(`{
		"sets":[{
			"id":"miner","name":"Miner",
			"slots":{},
			"tools":{"pickaxe":{"handed":"one"}}
		}]
	}`))
	if err == nil {
		t.Fatal("expected missing 1H slot error")
	}
}

func TestTwoHandedToolRejectsSlot(t *testing.T) {
	_, err := ParseSets([]byte(`{
		"sets":[{
			"id":"mage","name":"Mage",
			"slots":{},
			"tools":{"staff":{"handed":"two","slot":"right hand"}}
		}]
	}`))
	if err == nil {
		t.Fatal("expected 2H with slot error")
	}
}
