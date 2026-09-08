package questdef

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/devarminas/marque/server/internal/classdef"
)

const RelPath = "shared/quests.json"

type Deliver struct {
	Kind string `json:"kind"`
	Qty  int    `json:"qty"`
}

type Quest struct {
	ID          string
	Name        string
	TalkNPC     string
	Deliver     Deliver
	RewardSet   string
	RewardKinds []string
}

type Catalog struct {
	byID map[string]Quest
}

type fileQuest struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	TalkNPC   string  `json:"talk_npc"`
	Deliver   Deliver `json:"deliver"`
	RewardSet string  `json:"reward_set"`
}

type fileShape struct {
	Quests []fileQuest `json:"quests"`
}

func Load(path string, sets *classdef.Catalog) (*Catalog, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("questdef: empty path")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("questdef: read %s: %w", path, err)
	}
	return Parse(raw, sets)
}

func Parse(raw []byte, sets *classdef.Catalog) (*Catalog, error) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, fmt.Errorf("questdef: empty file")
	}
	var shape fileShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return nil, fmt.Errorf("questdef: malformed JSON: %w", err)
	}
	if len(shape.Quests) == 0 {
		return nil, fmt.Errorf("questdef: no quests in file")
	}
	if sets == nil {
		return nil, fmt.Errorf("questdef: nil sets catalog")
	}
	byID := make(map[string]Quest, len(shape.Quests))
	for i, rawQ := range shape.Quests {
		q, err := bind(rawQ, sets)
		if err != nil {
			return nil, fmt.Errorf("questdef: quests[%d]: %w", i, err)
		}
		if _, exists := byID[q.ID]; exists {
			return nil, fmt.Errorf("questdef: duplicate id %q", q.ID)
		}
		byID[q.ID] = q
	}
	return &Catalog{byID: byID}, nil
}

func bind(raw fileQuest, sets *classdef.Catalog) (Quest, error) {
	if raw.ID == "" {
		return Quest{}, fmt.Errorf("missing id")
	}
	if raw.Name == "" {
		return Quest{}, fmt.Errorf("%q: missing name", raw.ID)
	}
	if raw.TalkNPC == "" {
		return Quest{}, fmt.Errorf("%q: missing talk_npc", raw.ID)
	}
	if raw.Deliver.Kind == "" {
		return Quest{}, fmt.Errorf("%q: deliver.kind required", raw.ID)
	}
	if raw.Deliver.Qty < 1 {
		return Quest{}, fmt.Errorf("%q: deliver.qty must be >= 1", raw.ID)
	}
	if raw.RewardSet == "" {
		return Quest{}, fmt.Errorf("%q: reward_set required", raw.ID)
	}
	set, ok := sets.GetSet(raw.RewardSet)
	if !ok {
		return Quest{}, fmt.Errorf("%q: unknown reward_set %q", raw.ID, raw.RewardSet)
	}
	kinds, err := setRewardKinds(set)
	if err != nil {
		return Quest{}, fmt.Errorf("%q: reward_set %q: %w", raw.ID, raw.RewardSet, err)
	}
	return Quest{
		ID:          raw.ID,
		Name:        raw.Name,
		TalkNPC:     raw.TalkNPC,
		Deliver:     raw.Deliver,
		RewardSet:   raw.RewardSet,
		RewardKinds: kinds,
	}, nil
}

func setRewardKinds(s classdef.Set) ([]string, error) {
	if len(s.Slots) == 0 && len(s.Tools) == 0 {
		return nil, fmt.Errorf("set has no slots or tools")
	}
	slotKeys := make([]string, 0, len(s.Slots))
	for k := range s.Slots {
		slotKeys = append(slotKeys, k)
	}
	sort.Strings(slotKeys)
	out := make([]string, 0, len(s.Slots)+len(s.Tools))
	for _, slot := range slotKeys {
		kind := s.Slots[slot]
		if kind == "" {
			return nil, fmt.Errorf("slot %q has no kind", slot)
		}
		out = append(out, kind)
	}
	toolKeys := make([]string, 0, len(s.Tools))
	for k := range s.Tools {
		toolKeys = append(toolKeys, k)
	}
	sort.Strings(toolKeys)
	for _, kind := range toolKeys {
		if kind == "" {
			return nil, fmt.Errorf("empty tool kind")
		}
		out = append(out, kind)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no reward kinds")
	}
	return out, nil
}

func (c *Catalog) Get(id string) (Quest, bool) {
	q, ok := c.byID[id]
	return q, ok
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
	if env := strings.TrimSpace(os.Getenv("MARQUE_QUESTS")); env != "" {
		return env, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("questdef: getwd: %w", err)
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
	return "", fmt.Errorf("questdef: %s not found from %s (set MARQUE_QUESTS)", RelPath, cwd)
}
