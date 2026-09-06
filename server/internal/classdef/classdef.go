// Package classdef loads the shared class-system content tables: set → worn
// slot → item kind, and the skill list. It mirrors abilitydef: one table, one
// parse, fail closed. No class calculation lives here.
package classdef

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	SetsRelPath   = "shared/sets.json"
	SkillsRelPath = "shared/skills.json"
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

// Catalog is the validated, read-only form of both tables.
type Catalog struct {
	sets   map[string]Set
	skills map[string]Skill
}

type setsFileShape struct {
	Sets []Set `json:"sets"`
}

type skillsFileShape struct {
	Skills []Skill `json:"skills"`
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

func (c *Catalog) GetSet(id string) (Set, bool) {
	s, ok := c.sets[id]
	return s, ok
}

func (c *Catalog) GetSkill(id string) (Skill, bool) {
	sk, ok := c.skills[id]
	return sk, ok
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