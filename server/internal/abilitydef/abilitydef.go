package abilitydef

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const RelPath = "shared/abilities.json"

const (
	EffectHeal   = "heal"
	EffectDamage = "damage"

	TargetFriendly = "friendly"
	TargetHostile  = "hostile"
	TargetSelf     = "self"
)

type Effect struct {
	Kind   string  `json:"kind"`
	Amount float64 `json:"amount"`
}

type UI struct {
	HotbarSlot int    `json:"hotbar_slot"`
	Color      string `json:"color"`
}

type Ability struct {
	ID            string  `json:"id"`
	Name          string  `json:"name"`
	ManaCost      float64 `json:"mana_cost"`
	CooldownTicks int     `json:"cooldown_ticks"`
	Range         float64 `json:"range"`
	Target        string  `json:"target"`
	Effect        Effect  `json:"effect"`
	UI            UI      `json:"ui"`
}

type Catalog struct {
	byID map[string]Ability
}

type fileShape struct {
	Abilities []Ability `json:"abilities"`
}

func Load(path string) (*Catalog, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("abilitydef: empty path")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("abilitydef: read %s: %w", path, err)
	}
	return Parse(raw)
}

func Parse(raw []byte) (*Catalog, error) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, fmt.Errorf("abilitydef: empty file")
	}
	var shape fileShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return nil, fmt.Errorf("abilitydef: malformed JSON: %w", err)
	}
	if len(shape.Abilities) == 0 {
		return nil, fmt.Errorf("abilitydef: no abilities in file")
	}
	byID := make(map[string]Ability, len(shape.Abilities))
	for i, a := range shape.Abilities {
		if err := validate(a); err != nil {
			return nil, fmt.Errorf("abilitydef: abilities[%d]: %w", i, err)
		}
		if _, exists := byID[a.ID]; exists {
			return nil, fmt.Errorf("abilitydef: duplicate id %q", a.ID)
		}
		byID[a.ID] = a
	}
	return &Catalog{byID: byID}, nil
}

func validate(a Ability) error {
	if a.ID == "" {
		return fmt.Errorf("missing id")
	}
	if a.Name == "" {
		return fmt.Errorf("%q: missing name", a.ID)
	}
	if a.ManaCost < 0 {
		return fmt.Errorf("%q: mana_cost must be >= 0", a.ID)
	}
	if a.CooldownTicks < 0 {
		return fmt.Errorf("%q: cooldown_ticks must be >= 0", a.ID)
	}
	if a.Range < 0 {
		return fmt.Errorf("%q: range must be >= 0", a.ID)
	}
	switch a.Target {
	case TargetFriendly, TargetHostile, TargetSelf:
	default:
		return fmt.Errorf("%q: unknown target %q", a.ID, a.Target)
	}
	switch a.Effect.Kind {
	case EffectHeal, EffectDamage:
	default:
		return fmt.Errorf("%q: unknown effect.kind %q", a.ID, a.Effect.Kind)
	}
	if a.Target == TargetSelf && a.Effect.Kind == EffectDamage {
		return fmt.Errorf("%q: a self-targeted ability cannot damage its caster", a.ID)
	}
	if a.Effect.Amount < 0 {
		return fmt.Errorf("%q: effect.amount must be >= 0", a.ID)
	}
	if a.UI.Color == "" {
		return fmt.Errorf("%q: ui.color required", a.ID)
	}
	return nil
}

func (c *Catalog) Get(id string) (Ability, bool) {
	a, ok := c.byID[id]
	return a, ok
}

func (c *Catalog) IDs() []string {
	out := make([]string, 0, len(c.byID))
	for id := range c.byID {
		out = append(out, id)
	}
	return out
}

func (c *Catalog) Len() int {
	return len(c.byID)
}

func ResolvePath() (string, error) {
	if env := strings.TrimSpace(os.Getenv("MARQUE_ABILITIES")); env != "" {
		return env, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("abilitydef: getwd: %w", err)
	}
	dir := cwd
	for {
		candidate := filepath.Join(dir, filepath.FromSlash(RelPath))
		if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
			return candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("abilitydef: %s not found from %s (set MARQUE_ABILITIES)", RelPath, cwd)
}
