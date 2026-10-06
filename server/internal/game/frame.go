package game

import mnet "github.com/devarminas/marque/server/internal/net"

type EntityHandle interface{ entityHandle() }

func (PlayerHandle) entityHandle() {}
func (NPCHandle) entityHandle()    {}
func (ItemHandle) entityHandle()   {}
func (NodeHandle) entityHandle()   {}

type CombatantHandle interface {
	EntityHandle
	combatantHandle()
}

func (PlayerHandle) combatantHandle() {}
func (NPCHandle) combatantHandle()    {}

type TransformState struct{ X, Y, Z float64 }
type VitalsState struct{ HP, MaxHP, Mana, MaxMana int }
type GearState struct{ Slots []WornEntry }
type CastState struct {
	Ability         string
	Target          CombatantHandle
	Progress, Total int
}
type NodeAppearance struct {
	Skill    string
	Depleted bool
}
type NPCAppearance struct{ Faction, DisplayName string }
type AppearanceState struct {
	Kind string
	Node *NodeAppearance
	NPC  *NPCAppearance
}
type EntityState struct {
	Handle     EntityHandle
	Transform  TransformState
	Vitals     *VitalsState
	Gear       *GearState
	Cast       *CastState
	Appearance *AppearanceState
}
type StateFrame struct {
	Tick        uint32
	Entities    []EntityState
	OwnerMotion []MotionSnapshot
	Owners      []OwnerState
}

func (w *World) combatantHandle(id mnet.PlayerID) CombatantHandle {
	if id == 0 {
		return nil
	}
	if _, ok := w.npcs[id]; ok {
		return NPCHandle{uint32(id), 1}
	}
	return PlayerHandle{uint32(id), 1}
}
func (w *World) castState(c castRuntime) *CastState {
	if !c.casting() {
		return nil
	}
	return &CastState{c.castAbility, c.castHandle, c.castProgress, c.castTotal}
}
func (w *World) stateFrame() StateFrame {
	frame := StateFrame{Tick: uint32(w.tick)}
	for _, p := range w.order {
		gear := &GearState{}
		for _, slot := range w.items.Worn(p.id) {
			gear.Slots = append(gear.Slots, WornEntry{string(slot.Slot), slot.Kind})
		}
		h := PlayerHandle{uint32(p.id), 1}
		frame.Entities = append(frame.Entities, EntityState{Handle: h, Transform: TransformState{p.pos.X, p.y, p.pos.Z}, Vitals: &VitalsState{p.hp, p.attrs.maxHP(), p.mana, p.attrs.maxMana()}, Gear: gear, Cast: w.castState(p.castRuntime)})
		if p.domainOwned {
			snapshot, err := w.OwnerMotion(h)
			if err != nil {
				panic(err)
			}
			frame.OwnerMotion = append(frame.OwnerMotion, snapshot)
			frame.Owners = append(frame.Owners, w.ownerState(p))
		}
	}
	for _, id := range w.npcOrder {
		n := w.npcs[id]
		if n == nil {
			continue
		}
		frame.Entities = append(frame.Entities, EntityState{Handle: NPCHandle{uint32(n.id), 1}, Transform: TransformState{X: n.pos.X, Y: w.mapCfg.GroundY, Z: n.pos.Z}, Vitals: &VitalsState{HP: n.hp, MaxHP: n.maxHP}, Cast: w.castState(n.castRuntime), Appearance: &AppearanceState{Kind: n.kind, NPC: &NPCAppearance{n.faction, npcDisplayName(n.kind)}}})
	}
	for _, item := range w.items.GroundItems() {
		frame.Entities = append(frame.Entities, EntityState{Handle: ItemHandle{uint32(item.ID), 1}, Transform: TransformState{X: item.X, Y: w.mapCfg.GroundY, Z: item.Z}, Appearance: &AppearanceState{Kind: item.Kind}})
	}
	for _, id := range w.nodeOrder {
		n := w.nodes[id]
		if n == nil {
			continue
		}
		frame.Entities = append(frame.Entities, EntityState{Handle: NodeHandle{uint32(n.id), 1}, Transform: TransformState{X: n.x, Y: w.mapCfg.GroundY, Z: n.z}, Appearance: &AppearanceState{Kind: n.kind, Node: &NodeAppearance{n.skill, n.depleted}}})
	}
	return frame
}
