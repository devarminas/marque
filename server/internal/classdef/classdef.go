// Package classdef loads the shared class-system content tables: set → worn
// slot → item kind, the five class definitions, and the skill list. It mirrors
// abilitydef: one table, one parse, fail closed. ClassOf, the pure derivation
// from worn equipment, lives here so the class table and the function that
// reads it cannot disagree.
package classdef

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	SetsRelPath    = "shared/sets.json"
	SkillsRelPath  = "shared/skills.json"
	ClassesRelPath = "shared/classes.json"
)

const (
	HandedOne = "one"
	HandedTwo = "two"
)

// Tool is one entry in a set's tools table. Handed is unused by classdef; it
// is load-only transport for the 1H/2H equip unit (ARM-121).
type Tool struct {
	Handed string `json:"handed"`
}

// Set maps worn slots to the item kinds that complete it, plus the tool kinds
// it is used with. Slots is keyed by worn-slot name (helmet, chest, trousers,
// boots). Boots has no worn slot today; the key is data, not slot support.
type Set struct {
	ID    string            `json:"id"`
	Name  string            `json:"name"`
	Slots map[string]string `json:"slots"`
	Tools map[string]Tool   `json:"tools"`
}

type Skill struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	MaxLevel int    `json:"max_level"`
}

// Class is one of the five class definitions in shared/classes.json. Requires
// maps each worn slot the class needs to the item kind that must sit in it;
// the tool slots (right hand / left hand) are entries like any other, so a
// class is complete when every Requires entry is worn.
type Class struct {
	ID       string            `json:"id"`
	Name     string            `json:"name"`
	Skill    string            `json:"skill"`
	Requires map[string]string `json:"requires"`
}

// ClassResult is the pure output of ClassOf: which class the worn equipment
// composes, if a complete one, and what keeps the closest class from being
// active. Missing maps each worn slot that lacks its required kind to the kind
// that must sit there.
type ClassResult struct {
	Class   *Class
	Missing map[string]string
}

// XPPerLevel is the XP a level costs, the one number of the skill curve. A
// level is a pure function of XP (see SkillLevel); this constant is that
// curve's single knob. Tuning: ARM-122.
const XPPerLevel = 100

// Catalog is the validated, read-only form of the content tables.
type Catalog struct {
	sets    map[string]Set
	skills  map[string]Skill
	classes map[string]Class
}

type setsFileShape struct {
	Sets []Set `json:"sets"`
}

type skillsFileShape struct {
	Skills []Skill `json:"skills"`
}

type classesFileShape struct {
	Classes []Class `json:"classes"`
}

func LoadSets(path string) (*Catalog, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("classdef: empty sets path")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("classdef: read %s: %w", path, err)
	}
	return ParseSets(raw)
}

func ParseSets(raw []byte) (*Catalog, error) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, fmt.Errorf("classdef: empty sets file")
	}
	var shape setsFileShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return nil, fmt.Errorf("classdef: malformed sets JSON: %w", err)
	}
	if len(shape.Sets) == 0 {
		return nil, fmt.Errorf("classdef: no sets in file")
	}
	sets := make(map[string]Set, len(shape.Sets))
	for i, s := range shape.Sets {
		if err := validateSet(s); err != nil {
			return nil, fmt.Errorf("classdef: sets[%d]: %w", i, err)
		}
		if _, exists := sets[s.ID]; exists {
			return nil, fmt.Errorf("classdef: duplicate set id %q", s.ID)
		}
		sets[s.ID] = s
	}
	return &Catalog{sets: sets}, nil
}

func LoadSkills(path string) (*Catalog, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("classdef: empty skills path")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("classdef: read %s: %w", path, err)
	}
	return ParseSkills(raw)
}

func ParseSkills(raw []byte) (*Catalog, error) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, fmt.Errorf("classdef: empty skills file")
	}
	var shape skillsFileShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return nil, fmt.Errorf("classdef: malformed skills JSON: %w", err)
	}
	if len(shape.Skills) == 0 {
		return nil, fmt.Errorf("classdef: no skills in file")
	}
	skills := make(map[string]Skill, len(shape.Skills))
	for i, sk := range shape.Skills {
		if err := validateSkill(sk); err != nil {
			return nil, fmt.Errorf("classdef: skills[%d]: %w", i, err)
		}
		if _, exists := skills[sk.ID]; exists {
			return nil, fmt.Errorf("classdef: duplicate skill id %q", sk.ID)
		}
		skills[sk.ID] = sk
	}
	return &Catalog{skills: skills}, nil
}

func validateSet(s Set) error {
	if s.ID == "" {
		return fmt.Errorf("missing id")
	}
	if s.Name == "" {
		return fmt.Errorf("%q: missing name", s.ID)
	}
	for slot, kind := range s.Slots {
		if slot == "" {
			return fmt.Errorf("%q: empty slot name", s.ID)
		}
		if kind == "" {
			return fmt.Errorf("%q: slot %q has no kind", s.ID, slot)
		}
	}
	for kind, tool := range s.Tools {
		if kind == "" {
			return fmt.Errorf("%q: empty tool kind", s.ID)
		}
		switch tool.Handed {
		case HandedOne, HandedTwo:
		default:
			return fmt.Errorf("%q: unknown handed %q for tool %q", s.ID, tool.Handed, kind)
		}
	}
	return nil
}

func validateSkill(sk Skill) error {
	if sk.ID == "" {
		return fmt.Errorf("missing id")
	}
	if sk.Name == "" {
		return fmt.Errorf("%q: missing name", sk.ID)
	}
	if sk.MaxLevel < 1 {
		return fmt.Errorf("%q: max_level must be >= 1", sk.ID)
	}
	return nil
}

func LoadClasses(path string) (*Catalog, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("classdef: empty classes path")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("classdef: read %s: %w", path, err)
	}
	return ParseClasses(raw)
}

func ParseClasses(raw []byte) (*Catalog, error) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, fmt.Errorf("classdef: empty classes file")
	}
	var shape classesFileShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return nil, fmt.Errorf("classdef: malformed classes JSON: %w", err)
	}
	if len(shape.Classes) == 0 {
		return nil, fmt.Errorf("classdef: no classes in file")
	}
	classes := make(map[string]Class, len(shape.Classes))
	for i, c := range shape.Classes {
		if err := validateClass(c); err != nil {
			return nil, fmt.Errorf("classdef: classes[%d]: %w", i, err)
		}
		if _, exists := classes[c.ID]; exists {
			return nil, fmt.Errorf("classdef: duplicate class id %q", c.ID)
		}
		classes[c.ID] = c
	}
	return &Catalog{classes: classes}, nil
}

func validateClass(c Class) error {
	if c.ID == "" {
		return fmt.Errorf("missing id")
	}
	if c.Name == "" {
		return fmt.Errorf("%q: missing name", c.ID)
	}
	if c.Skill == "" {
		return fmt.Errorf("%q: missing skill", c.ID)
	}
	if len(c.Requires) == 0 {
		return fmt.Errorf("%q: empty requires", c.ID)
	}
	for slot, kind := range c.Requires {
		if slot == "" {
			return fmt.Errorf("%q: empty slot name", c.ID)
		}
		if kind == "" {
			return fmt.Errorf("%q: slot %q has no kind", c.ID, slot)
		}
	}
	return nil
}

func (c *Catalog) GetSet(id string) (Set, bool) {
	s, ok := c.sets[id]
	return s, ok
}

func (c *Catalog) GetSkill(id string) (Skill, bool) {
	sk, ok := c.skills[id]
	return sk, ok
}

func (c *Catalog) GetClass(id string) (Class, bool) {
	cl, ok := c.classes[id]
	return cl, ok
}

const defaultSkillMaxLevel = 99

// SkillLevel is the level for xp, the pure function the brief demands: level
// 1 at zero XP, one level per XPPerLevel, never above max. The max is the
// skill's max_level when the catalog carries the skill, else the shared
// default; both are data, never per-player state.
func SkillLevel(xp int64, max int) int {
	if xp < 0 {
		xp = 0
	}
	level := 1 + int(xp/XPPerLevel)
	if max > 0 && level > max {
		return max
	}
	if level > defaultSkillMaxLevel {
		return defaultSkillMaxLevel
	}
	return level
}

func (c *Catalog) LevelFor(skill string, xp int64) int {
	max := 0
	if sk, ok := c.GetSkill(skill); ok {
		max = sk.MaxLevel
	}
	return SkillLevel(xp, max)
}

func (c *Catalog) ClassIDs() []string {
	out := make([]string, 0, len(c.classes))
	for id := range c.classes {
		out = append(out, id)
	}
	return out
}

func (c *Catalog) ClassLen() int {
	return len(c.classes)
}

func (c *Catalog) classOrder() []Class {
	out := make([]Class, 0, len(c.classes))
	for _, id := range c.ClassIDs() {
		cl, _ := c.GetClass(id)
		out = append(out, cl)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// ClassOf derives the class worn equipment composes.
//
// A class is active when every slot its Requires names is worn with the named
// kind. The tool slots are entries like any other, so "full set + tool" falls
// out of one table. Otherwise no class is active (Class is nil) and Missing
// names what the closest class still needs: every slot that lacks its required
// kind, keyed by slot name. Nil worn (or nil Catalog) returns an empty result;
// a non-nil empty map still reports the closest class's Missing.
func ClassOf(worn map[string]string, classes *Catalog) ClassResult {
	if classes == nil || worn == nil {
		return ClassResult{}
	}
	bestMissing := map[string]string(nil)
	bestSatisfied := -1
	for _, cl := range classes.classOrder() {
		missing := make(map[string]string)
		satisfied := 0
		for slot, kind := range cl.Requires {
			if worn[slot] == kind {
				satisfied++
			} else {
				missing[slot] = kind
			}
		}
		if satisfied == len(cl.Requires) {
			return ClassResult{Class: &cl}
		}
		if satisfied > bestSatisfied {
			bestSatisfied = satisfied
			bestMissing = missing
		}
	}
	return ClassResult{Missing: bestMissing}
}

// WireMissing splits a ClassResult's Missing map the way the wire carries it:
// slot entries that name a worn slot, and tool kinds that name no worn slot.
// Slots sorts by WornSlots order, then any remainder by kind; Tools sorts by
// kind. A nil or empty Missing yields empty slices, never nil.
func WireMissing(missing map[string]string, wornSlots []mnet.EquipSlot) (slots []mnet.NamedSlot, tools []string) {
	slots = make([]mnet.NamedSlot, 0, len(missing))
	tools = make([]string, 0, len(missing))
	for slot, kind := range missing {
		if isWornSlot(slot, wornSlots) {
			slots = append(slots, mnet.NamedSlot{Slot: slot, Kind: kind})
		} else {
			tools = append(tools, kind)
		}
	}
	sort.Slice(slots, func(i, j int) bool {
		oi, oiOK := wornSlotOrder(slots[i].Slot, wornSlots)
		oj, ojOK := wornSlotOrder(slots[j].Slot, wornSlots)
		switch {
		case oiOK && ojOK:
			return oi < oj
		case oiOK:
			return true
		case ojOK:
			return false
		default:
			return slots[i].Slot < slots[j].Slot
		}
	})
	sort.Strings(tools)
	return slots, tools
}

func isWornSlot(name string, wornSlots []mnet.EquipSlot) bool {
	for _, s := range wornSlots {
		if string(s) == name {
			return true
		}
	}
	return false
}

func wornSlotOrder(name string, wornSlots []mnet.EquipSlot) (int, bool) {
	for i, s := range wornSlots {
		if string(s) == name {
			return i, true
		}
	}
	return 0, false
}

// ResolveClassesPath finds shared/classes.json from cwd or parents, or from
// MARQUE_CLASSES when set.
func ResolveClassesPath() (string, error) {
	if env := strings.TrimSpace(os.Getenv("MARQUE_CLASSES")); env != "" {
		return env, nil
	}
	return resolvePath(ClassesRelPath, "classdef")
}

// LoadAll composes the three shared content files — sets, skills, classes —
// into one Catalog, resolved from cwd or parents (or the MARQUE_* env vars).
// The world's SetClasses wants one catalog carrying both the class table and
// the skills table, because ClassOf reads the classes and the level function
// reads the skills. A load failure fails closed.
func LoadAll() (*Catalog, error) {
	setsPath, err := ResolveSetsPath()
	if err != nil {
		return nil, err
	}
	skillsPath, err := ResolveSkillsPath()
	if err != nil {
		return nil, err
	}
	classesPath, err := ResolveClassesPath()
	if err != nil {
		return nil, err
	}
	setsCat, err := LoadSets(setsPath)
	if err != nil {
		return nil, err
	}
	skillsCat, err := LoadSkills(skillsPath)
	if err != nil {
		return nil, err
	}
	classesCat, err := LoadClasses(classesPath)
	if err != nil {
		return nil, err
	}
	cat := &Catalog{}
	cat.sets = setsCat.sets
	cat.skills = skillsCat.skills
	cat.classes = classesCat.classes
	return cat, nil
}

func (c *Catalog) SetIDs() []string {
	out := make([]string, 0, len(c.sets))
	for id := range c.sets {
		out = append(out, id)
	}
	return out
}

func (c *Catalog) SkillIDs() []string {
	out := make([]string, 0, len(c.skills))
	for id := range c.skills {
		out = append(out, id)
	}
	return out
}

func (c *Catalog) SetLen() int {
	return len(c.sets)
}

func (c *Catalog) SkillLen() int {
	return len(c.skills)
}

// ResolveSetsPath finds shared/sets.json from cwd or parents, or from
// MARQUE_SETS when set.
func ResolveSetsPath() (string, error) {
	if env := strings.TrimSpace(os.Getenv("MARQUE_SETS")); env != "" {
		return env, nil
	}
	return resolvePath(SetsRelPath, "classdef")
}

// ResolveSkillsPath finds shared/skills.json from cwd or parents, or from
// MARQUE_SKILLS when set.
func ResolveSkillsPath() (string, error) {
	if env := strings.TrimSpace(os.Getenv("MARQUE_SKILLS")); env != "" {
		return env, nil
	}
	return resolvePath(SkillsRelPath, "classdef")
}

func resolvePath(rel, pkg string) (string, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("%s: getwd: %w", pkg, err)
	}
	dir := cwd
	for {
		candidate := filepath.Join(dir, filepath.FromSlash(rel))
		if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
			return candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("%s: %s not found from %s (set MARQUE_SETS or MARQUE_SKILLS)", pkg, rel, cwd)
}