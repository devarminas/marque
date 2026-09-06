package game

import (
	"errors"
	"fmt"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	KindDummy = "dummy"

	FactionFriendly = "friendly"
	FactionHostile  = "hostile"

	FriendlyDummyX = -3.0
	FriendlyDummyZ = 0.0
	EnemyDummyX    = 3.0
	EnemyDummyZ    = 0.0

	practiceNpcIDBand mnet.PlayerID = 1_000_000

	EvNpcSpawned = "npc_spawned"
)

type npc struct {
	id      mnet.PlayerID
	kind    string
	faction string
	pos     Point
	hp      int
}

func (n *npc) dead() bool { return n.hp == 0 }

func (n *npc) wire() mnet.NpcState {
	return mnet.NpcState{
		ID:      n.id,
		Kind:    n.kind,
		Faction: n.faction,
		X:       n.pos.X,
		Z:       n.pos.Z,
		HP:      n.hp,
		MaxHP:   MaxHP,
	}
}

// SeedPracticeDummies places one friendly and one enemy stationary dummy.
func (w *World) SeedPracticeDummies() error {
	if err := w.seedNpc(KindDummy, FactionFriendly, FriendlyDummyX, FriendlyDummyZ); err != nil {
		return err
	}
	return w.seedNpc(KindDummy, FactionHostile, EnemyDummyX, EnemyDummyZ)
}

func (w *World) seedNpc(kind, faction string, x, z float64) error {
	if kind == "" {
		return errors.New("seed npc: kind must not be empty")
	}
	if faction != FactionFriendly && faction != FactionHostile {
		return fmt.Errorf("seed npc: unknown faction %q", faction)
	}
	if reason, detail := checkCoordinates(x, z); reason != "" {
		return fmt.Errorf("seed npc %q at (%v, %v): %s", kind, x, z, detail)
	}
	w.nextNpcID++
	n := &npc{
		id:      practiceNpcIDBand + w.nextNpcID,
		kind:    kind,
		faction: faction,
		pos:     Point{X: x, Z: z},
		hp:      MaxHP,
	}
	w.npcs[n.id] = n
	w.npcOrder = append(w.npcOrder, n.id)
	w.log.Event(w.tick, EvNpcSpawned, gamelog.Fields{
		"npc":     n.id,
		"kind":    n.kind,
		"faction": n.faction,
		"x":       n.pos.X,
		"z":       n.pos.Z,
	})
	return nil
}

func (w *World) npcStates() []mnet.NpcState {
	states := make([]mnet.NpcState, 0, len(w.npcOrder))
	for _, id := range w.npcOrder {
		n, ok := w.npcs[id]
		if !ok {
			continue
		}
		states = append(states, n.wire())
	}
	return states
}

func (w *World) broadcastNPCHP(n *npc) {
	w.broadcast(mnet.HP{ID: n.id, HP: n.hp, MaxHP: MaxHP}, nil)
}

// SetNPCHitPointsByFaction sets HP on the first seeded NPC of faction.
func (w *World) SetNPCHitPointsByFaction(faction string, hp int) error {
	if faction != FactionFriendly && faction != FactionHostile {
		return fmt.Errorf("set npc hp: unknown faction %q", faction)
	}
	if hp < 0 || hp > MaxHP {
		return fmt.Errorf("set npc hp: hp %d out of range [0,%d]", hp, MaxHP)
	}
	for _, id := range w.npcOrder {
		n, ok := w.npcs[id]
		if !ok || n.faction != faction {
			continue
		}
		n.hp = hp
		w.log.Event(w.tick, "npc_hp_seed", gamelog.Fields{
			"npc":     n.id,
			"faction": n.faction,
			"hp":      n.hp,
		})
		return nil
	}
	return fmt.Errorf("set npc hp: no %s dummy seeded", faction)
}
