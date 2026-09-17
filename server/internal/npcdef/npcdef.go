package npcdef

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const RelPath = "shared/npc_archetypes.json"

const (
	Imp = "imp"

	// hpPerCON matches game.HPPerCON. max_hp must equal 10 * con so the
	// JSON file is not a second HP formula.
	hpPerCON = 10
)

type Archetype struct {
	ID           string   `json:"id"`
	MaxHP        int      `json:"max_hp"`
	WeaponID     string   `json:"weapon_id"`
	Threat       float64  `json:"threat"`
	Leash        float64  `json:"leash"`
	Wander       float64  `json:"wander"`
	Skills       []string `json:"skills"`
	IdleMinTicks int      `json:"idle_min_ticks"`
	IdleMaxTicks int      `json:"idle_max_ticks"`
	STR          int      `json:"str"`
	DEX          int      `json:"dex"`
	CON          int      `json:"con"`
	INT          int      `json:"int"`
}

func (a Archetype) SkillID() string {
	if len(a.Skills) == 0 {
		return ""
	}
	return a.Skills[0]
}

type Catalog struct {
	byID map[string]Archetype
}

type fileShape struct {
	Archetypes []Archetype `json:"archetypes"`
}

func Load(path string) (*Catalog, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("npcdef: empty path")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("npcdef: read %s: %w", path, err)
	}
	return Parse(raw)
}

func Parse(raw []byte) (*Catalog, error) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, fmt.Errorf("npcdef: empty file")
	}
	var shape fileShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return nil, fmt.Errorf("npcdef: malformed JSON: %w", err)
	}
	if len(shape.Archetypes) == 0 {
		return nil, fmt.Errorf("npcdef: no archetypes in file")
	}
	byID := make(map[string]Archetype, len(shape.Archetypes))
	for i, a := range shape.Archetypes {
		if err := validate(a); err != nil {
			return nil, fmt.Errorf("npcdef: archetypes[%d]: %w", i, err)
		}
		if _, exists := byID[a.ID]; exists {
			return nil, fmt.Errorf("npcdef: duplicate id %q", a.ID)
		}
		byID[a.ID] = a
	}
	if _, ok := byID[Imp]; !ok {
		return nil, fmt.Errorf("npcdef: missing required id %q", Imp)
	}
	return &Catalog{byID: byID}, nil
}

func validate(a Archetype) error {
	if a.ID == "" {
		return fmt.Errorf("missing id")
	}
	if a.MaxHP < 1 {
		return fmt.Errorf("%q: max_hp must be >= 1", a.ID)
	}
	if strings.TrimSpace(a.WeaponID) == "" {
		return fmt.Errorf("%q: missing weapon_id", a.ID)
	}
	if a.Threat <= 0 {
		return fmt.Errorf("%q: threat must be > 0", a.ID)
	}
	if a.Leash <= 0 {
		return fmt.Errorf("%q: leash must be > 0", a.ID)
	}
	if a.Wander <= 0 {
		return fmt.Errorf("%q: wander must be > 0", a.ID)
	}
	if a.Wander >= a.Leash {
		return fmt.Errorf("%q: wander %v must be < leash %v", a.ID, a.Wander, a.Leash)
	}
	if len(a.Skills) == 0 {
		return fmt.Errorf("%q: skills must not be empty", a.ID)
	}
	for i, skill := range a.Skills {
		if strings.TrimSpace(skill) == "" {
			return fmt.Errorf("%q: skills[%d] is empty", a.ID, i)
		}
	}
	if a.IdleMinTicks < 1 {
		return fmt.Errorf("%q: idle_min_ticks must be >= 1", a.ID)
	}
	if a.IdleMaxTicks < a.IdleMinTicks {
		return fmt.Errorf("%q: idle_max_ticks must be >= idle_min_ticks", a.ID)
	}
	if a.STR < 1 || a.DEX < 1 || a.CON < 1 || a.INT < 1 {
		return fmt.Errorf("%q: str/dex/con/int must be >= 1", a.ID)
	}
	if a.MaxHP != hpPerCON*a.CON {
		return fmt.Errorf("%q: max_hp %d must equal %d * con %d", a.ID, a.MaxHP, hpPerCON, a.CON)
	}
	return nil
}

func (c *Catalog) Get(id string) (Archetype, bool) {
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
	if env := strings.TrimSpace(os.Getenv("MARQUE_NPC_ARCHETYPES")); env != "" {
		return env, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("npcdef: getwd: %w", err)
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
	return "", fmt.Errorf("npcdef: %s not found from %s (set MARQUE_NPC_ARCHETYPES)", RelPath, cwd)
}
