package game

import (
	"sort"

	"github.com/devarminas/marque/server/internal/classdef"
	mnet "github.com/devarminas/marque/server/internal/net"
)

type OwnerState struct {
	Player PlayerHandle
	Values []OwnerValue
}

func (w *World) inventoryValue(p *player) InventoryValue {
	value := InventoryValue{Size: InventorySize}
	for _, slot := range w.items.Inventory(p.id) {
		value.Slots = append(value.Slots, BagEntry{uint8(slot.Index), slot.Kind})
	}
	return value
}
func (w *World) equipmentValue(p *player) EquipmentValue {
	value := EquipmentValue{}
	for _, slot := range WornSlots {
		value.Worn = append(value.Worn, string(slot))
	}
	for _, slot := range w.items.Worn(p.id) {
		value.Slots = append(value.Slots, WornEntry{string(slot.Slot), slot.Kind})
	}
	return value
}
func (w *World) classValue(p *player) ClassValue {
	value := ClassValue{}
	if w.classes == nil {
		return value
	}
	result := classdef.ClassOf(w.wornKinds(p), w.classes)
	if result.Class != nil {
		value.ID = result.Class.ID
		return value
	}
	for _, slot := range WornSlots {
		if kind, ok := result.Missing[string(slot)]; ok {
			value.MissingSlots = append(value.MissingSlots, WornEntry{string(slot), kind})
		}
	}
	for slot, kind := range result.Missing {
		if !wornSlotExists(mnet.EquipSlot(slot)) {
			value.MissingTools = append(value.MissingTools, kind)
		}
	}
	sort.Strings(value.MissingTools)
	return value
}
func (w *World) skillsValue(p *player) SkillsValue {
	value := SkillsValue{}
	if w.classes == nil {
		return value
	}
	ids := w.classes.SkillIDs()
	sort.Strings(ids)
	for _, id := range ids {
		value.Skills = append(value.Skills, SkillEntry{id, p.skillXP[id], uint32(w.classes.LevelFor(id, p.skillXP[id]))})
	}
	return value
}
func (w *World) questLogValue(p *player) QuestLogValue {
	value := QuestLogValue{Quests: make([]QuestEntry, 0, len(p.quests))}
	ids := make([]string, 0, len(p.quests))
	for id := range p.quests {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		entry := QuestEntry{ID: id, Status: string(p.quests[id])}
		if w.quests != nil {
			if q, ok := w.quests.Get(id); ok {
				entry.Title = q.Name
				entry.Objective = questObjective(q, p.questKillCount(id))
			}
		}
		value.Quests = append(value.Quests, entry)
	}
	return value
}
func partyValue(pt *party) PartyValue {
	value := PartyValue{ID: uint64(pt.id), Leader: PlayerHandle{uint32(pt.leader), 1}}
	for _, id := range pt.members {
		value.Members = append(value.Members, PlayerHandle{uint32(id), 1})
	}
	return value
}
func (w *World) ownerState(p *player) OwnerState {
	value := OwnerState{Player: PlayerHandle{uint32(p.id), 1}, Values: []OwnerValue{w.inventoryValue(p), w.equipmentValue(p), w.classValue(p), w.skillsValue(p), w.questLogValue(p)}}
	if pt := w.parties[p.partyID]; pt != nil {
		value.Values = append(value.Values, partyValue(pt))
	} else {
		value.Values = append(value.Values, PartyClearValue{})
	}
	if p.pendingInviteFrom != 0 {
		value.Values = append(value.Values, InviteValue{PlayerHandle{uint32(p.pendingInviteFrom), 1}})
	} else {
		value.Values = append(value.Values, InviteClearValue{})
	}
	if n := w.npcs[p.dialogNPC]; n != nil {
		if q, ok := w.questForTalkNPC(n.kind); ok {
			value.Values = append(value.Values, w.dialogValue(p, n, q))
		}
	}
	ids := make([]string, 0, len(p.cooldowns.readyAt))
	for id := range p.cooldowns.readyAt {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		ready := p.cooldowns.readyAt[id]
		if ready > w.tick {
			value.Values = append(value.Values, CooldownValue{id, uint32(ready)})
		}
	}
	return value
}
