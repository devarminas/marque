package weapondef

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const RelPath = "shared/weapons.json"

const (
	Unarmed = "unarmed"
	Sword   = "sword"
	Staff   = "staff"
	Bow     = "bow"
	ImpClaw = "imp_claw"
)

type Weapon struct {
	ID                string `json:"id"`
	AttackPeriodTicks int    `json:"attack_period_ticks"`
}

type Catalog struct {
	byID map[string]Weapon
}

type fileShape struct {
	Weapons []Weapon `json:"weapons"`
}

func Load(path string) (*Catalog, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("weapondef: empty path")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("weapondef: read %s: %w", path, err)
	}
	return Parse(raw)
}

func Parse(raw []byte) (*Catalog, error) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, fmt.Errorf("weapondef: empty file")
	}
	var shape fileShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return nil, fmt.Errorf("weapondef: malformed JSON: %w", err)
	}
	if len(shape.Weapons) == 0 {
		return nil, fmt.Errorf("weapondef: no weapons in file")
	}
	byID := make(map[string]Weapon, len(shape.Weapons))
	for i, w := range shape.Weapons {
		if err := validate(w); err != nil {
			return nil, fmt.Errorf("weapondef: weapons[%d]: %w", i, err)
		}
		if _, exists := byID[w.ID]; exists {
			return nil, fmt.Errorf("weapondef: duplicate id %q", w.ID)
		}
		byID[w.ID] = w
	}
	if _, ok := byID[Unarmed]; !ok {
		return nil, fmt.Errorf("weapondef: missing required id %q", Unarmed)
	}
	return &Catalog{byID: byID}, nil
}

func validate(w Weapon) error {
	if w.ID == "" {
		return fmt.Errorf("missing id")
	}
	if w.AttackPeriodTicks < 1 {
		return fmt.Errorf("%q: attack_period_ticks must be >= 1", w.ID)
	}
	return nil
}

func (c *Catalog) Get(id string) (Weapon, bool) {
	w, ok := c.byID[id]
	return w, ok
}

func (c *Catalog) Period(id string) (int, bool) {
	w, ok := c.byID[id]
	if !ok {
		return 0, false
	}
	return w.AttackPeriodTicks, true
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

// IncompleteCatalog builds a catalog without requiring unarmed.
// Production must use Load/Parse; game tests use this to exercise
// attackPeriodTicks fail-closed paths that Parse cannot reach.
func IncompleteCatalog(weapons []Weapon) *Catalog {
	byID := make(map[string]Weapon, len(weapons))
	for _, w := range weapons {
		byID[w.ID] = w
	}
	return &Catalog{byID: byID}
}

func ResolvePath() (string, error) {
	if env := strings.TrimSpace(os.Getenv("MARQUE_WEAPONS")); env != "" {
		return env, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("weapondef: getwd: %w", err)
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
	return "", fmt.Errorf("weapondef: %s not found from %s (set MARQUE_WEAPONS)", RelPath, cwd)
}
