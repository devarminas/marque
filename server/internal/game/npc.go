package game

import (
	"errors"
	"fmt"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	KindDummy      = "dummy"
	KindQuestGiver = "quest_giver"
	KindImpQuestGiver = "imp_quest_giver"
	KindImp        = "imp"

	FactionFriendly = "friendly"
	FactionHostile  = "hostile"
	FactionNeutral  = "neutral"

	FriendlyDummyX = -3.0
	FriendlyDummyZ = 0.0
	EnemyDummyX    = 3.0
	EnemyDummyZ    = 0.0
	QuestGiverX    = 0.0
	QuestGiverZ    = -4.0

	ImpQuestGiverX = 4.0
	ImpQuestGiverZ = -4.0

	// Starter-town Imp camp center (ARM-207 pool).
	ImpCampX = 12.0
	ImpCampZ = 8.0

	DummyMaxHP      = 100000
	DummyMinHP      = 1

	ImpMaxHP        = 50
	ImpDamage       = 5
	ImpThreatRange  = 8.0
	ImpLeashRange   = 16.0
	ImpPatrolRadius = 3.0

	practiceNpcIDBand mnet.PlayerID = 1_000_000

	EvNpcSpawned = "npc_spawned"
	EvNpcAggro   = "npc_aggro"
	EvNpcLeash   = "npc_leash"
)

type npcPhase uint8

const (
	phaseIdle npcPhase = iota
	phaseCombat
	phaseReturn
)

type npc struct {
	id      mnet.PlayerID
	kind    string
	faction string
	pos     Point
	hp      int
	maxHP   int

	camp           string
	home           Point
	remaining      []Point
	phase          npcPhase
	target         mnet.PlayerID
	attackProgress int
	patrolOut      bool
}

func (n *npc) dead() bool { return n.hp == 0 }

func (n *npc) floorPracticeHP() {
	if n.kind != KindDummy {
		return
	}
	if n.hp < DummyMinHP {
		n.hp = DummyMinHP
	}
}

func (n *npc) mobile() bool { return n.kind == KindImp }

func (n *npc) wire() mnet.NpcState {
	return mnet.NpcState{
		ID:      n.id,
		Kind:    n.kind,
		Faction: n.faction,
		X:       n.pos.X,
		Z:       n.pos.Z,
		HP:      n.hp,
		MaxHP:   n.maxHP,
	}
}

func (w *World) SeedPracticeDummies() error {
	if err := w.seedNPC(KindDummy, FactionFriendly, FriendlyDummyX, FriendlyDummyZ, DummyMaxHP); err != nil {
		return err
	}
	return w.seedNPC(KindDummy, FactionHostile, EnemyDummyX, EnemyDummyZ, DummyMaxHP)
}

func (w *World) SeedQuestGiver() error {
	return w.seedNPC(KindQuestGiver, FactionNeutral, QuestGiverX, QuestGiverZ, MaxHP)
}

func (w *World) SeedImpQuestGiver() error {
	return w.seedNPC(KindImpQuestGiver, FactionNeutral, ImpQuestGiverX, ImpQuestGiverZ, MaxHP)
}

func (w *World) seedNPC(kind, faction string, x, z float64, maxHP int) error {
	return w.seedNPCAt(kind, faction, x, z, maxHP, "")
}

func (w *World) seedNPCAt(kind, faction string, x, z float64, maxHP int, camp string) error {
	if kind == "" {
		return errors.New("seed npc: kind must not be empty")
	}
	if faction != FactionFriendly && faction != FactionHostile && faction != FactionNeutral {
		return fmt.Errorf("seed npc: unknown faction %q", faction)
	}
	if maxHP < 1 {
		return fmt.Errorf("seed npc: maxHP %d must be >= 1", maxHP)
	}
	if reason, detail := w.checkCoordinates(x, z); reason != "" {
		return fmt.Errorf("seed npc %q at (%v, %v): %s", kind, x, z, detail)
	}
	w.nextNpcID++
	n := &npc{
		id:      practiceNpcIDBand + w.nextNpcID,
		kind:    kind,
		faction: faction,
		pos:     Point{X: x, Z: z},
		hp:      maxHP,
		maxHP:   maxHP,
		camp:    camp,
	}
	w.npcs[n.id] = n
	w.npcOrder = append(w.npcOrder, n.id)
	fields := gamelog.Fields{
		"npc":     n.id,
		"kind":    n.kind,
		"faction": n.faction,
		"x":       n.pos.X,
		"z":       n.pos.Z,
		"max_hp":  n.maxHP,
	}
	if camp != "" {
		fields["camp"] = camp
	}
	w.log.Event(w.tick, EvNpcSpawned, fields)
	w.broadcast(mnet.NpcSpawn(n.wire()), nil)
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
	w.broadcast(mnet.HP{ID: n.id, HP: n.hp, MaxHP: n.maxHP}, nil)
}

func (w *World) SetNPCHitPointsByFaction(faction string, hp int) error {
	if faction != FactionFriendly && faction != FactionHostile {
		return fmt.Errorf("set npc hp: unknown faction %q", faction)
	}
	if hp < 0 || hp > DummyMaxHP {
		return fmt.Errorf("set npc hp: hp %d out of range [0,%d]", hp, DummyMaxHP)
	}
	for _, id := range w.npcOrder {
		n, ok := w.npcs[id]
		if !ok || n.faction != faction || n.kind != KindDummy {
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

// SetHostileKindHitPoints sets live hostile NPCs of kind to hp.
// Thin WS quest probes use this so a solo kill credit stays inside the ladder budget.
func (w *World) SetHostileKindHitPoints(kind string, hp int) error {
	if kind == "" {
		return fmt.Errorf("set hostile kind hp: kind must not be empty")
	}
	if hp < 1 || hp > DummyMaxHP {
		return fmt.Errorf("set hostile kind hp: hp %d out of range [1,%d]", hp, DummyMaxHP)
	}
	n := 0
	for _, id := range w.npcOrder {
		npc, ok := w.npcs[id]
		if !ok || npc.faction != FactionHostile || npc.kind != kind {
			continue
		}
		npc.hp = hp
		n++
	}
	if n == 0 {
		return fmt.Errorf("set hostile kind hp: no %q hostile seeded", kind)
	}
	return nil
}

func (w *World) despawnNPC(n *npc) {
	delete(w.npcs, n.id)
	order := w.npcOrder[:0]
	for _, id := range w.npcOrder {
		if id == n.id {
			continue
		}
		order = append(order, id)
	}
	w.npcOrder = order
	w.broadcast(mnet.Despawn{ID: n.id}, nil)
}

func (w *World) npcByKind(kind string) *npc {
	for _, id := range w.npcOrder {
		n := w.npcs[id]
		if n != nil && n.kind == kind {
			return n
		}
	}
	return nil
}
