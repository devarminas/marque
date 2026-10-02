package game

import (
	"fmt"
	mnet "github.com/devarminas/marque/server/internal/net"
	"slices"
)

type PlayerHandle struct {
	Index uint32
	Gen   uint32
}
type ItemHandle struct {
	Index uint32
	Gen   uint32
}
type NodeHandle struct {
	Index uint32
	Gen   uint32
}
type NPCHandle struct {
	Index uint32
	Gen   uint32
}
type OriginSource uint8

const (
	OriginInput  OriginSource = 1
	OriginIntent OriginSource = 2
)

type Origin struct {
	Source OriginSource
	Seq    uint32
}
type RefusalReason uint32

const (
	ReasonUnknownAbility   RefusalReason = 1
	ReasonNoTarget         RefusalReason = 2
	ReasonWrongTarget      RefusalReason = 3
	ReasonInsufficientMana RefusalReason = 4
	ReasonOutOfRange       RefusalReason = 5
	ReasonCooldown         RefusalReason = 6
	ReasonDead             RefusalReason = 7
	ReasonProtocolError    RefusalReason = 8
	ReasonIllegalSample    RefusalReason = 9
	ReasonUnknownItem      RefusalReason = 10
	ReasonNoSuchSlot       RefusalReason = 11
	ReasonEmptySlot        RefusalReason = 12
	ReasonNotEquippable    RefusalReason = 13
	ReasonNoSuchWornSlot   RefusalReason = 14
	ReasonEmptyWornSlot    RefusalReason = 15
	ReasonInventoryFull    RefusalReason = 16
	ReasonUnknownNode      RefusalReason = 17
	ReasonNodeDepleted     RefusalReason = 18
	ReasonNeedsClass       RefusalReason = 19
	ReasonNoRecipe         RefusalReason = 20
	ReasonMissingMat       RefusalReason = 21
	ReasonUnknownPlayer    RefusalReason = 22
	ReasonSelf             RefusalReason = 23
	ReasonTargetDead       RefusalReason = 24
	ReasonNotDead          RefusalReason = 25
	ReasonNoDialog         RefusalReason = 26
	ReasonUnknownOption    RefusalReason = 27
	ReasonQuestActive      RefusalReason = 28
	ReasonQuestComplete    RefusalReason = 29
	ReasonQuestInactive    RefusalReason = 30
	ReasonQuestIncomplete  RefusalReason = 31
	ReasonWrongItem        RefusalReason = 32
	ReasonNotLeader        RefusalReason = 33
	ReasonPartyFull        RefusalReason = 34
	ReasonAlreadyInParty   RefusalReason = 35
	ReasonDuplicateInvite  RefusalReason = 36
	ReasonNoInvite         RefusalReason = 37
	ReasonNotInParty       RefusalReason = 38
	ReasonNotSameParty     RefusalReason = 39
	ReasonUnauthorized     RefusalReason = 40
	ReasonUsage            RefusalReason = 41
	ReasonNonFinite        RefusalReason = 42
	ReasonOutOfBounds      RefusalReason = 43
)

func domainReason(r mnet.RejectReason) RefusalReason {
	switch r {
	case mnet.ReasonUnknownAbility:
		return ReasonUnknownAbility
	case mnet.ReasonNoTarget:
		return ReasonNoTarget
	case mnet.ReasonWrongTarget:
		return ReasonWrongTarget
	case mnet.ReasonInsufficientMana:
		return ReasonInsufficientMana
	case mnet.ReasonOutOfRange:
		return ReasonOutOfRange
	case mnet.ReasonCooldown:
		return ReasonCooldown
	case mnet.ReasonDead:
		return ReasonDead
	case mnet.ReasonProtocolError:
		return ReasonProtocolError
	case mnet.ReasonIllegalSample:
		return ReasonIllegalSample
	case mnet.ReasonUnknownItem:
		return ReasonUnknownItem
	case mnet.ReasonNoSuchSlot:
		return ReasonNoSuchSlot
	case mnet.ReasonEmptySlot:
		return ReasonEmptySlot
	case mnet.ReasonNotEquippable:
		return ReasonNotEquippable
	case mnet.ReasonNoSuchWornSlot:
		return ReasonNoSuchWornSlot
	case mnet.ReasonEmptyWornSlot:
		return ReasonEmptyWornSlot
	case mnet.ReasonInventoryFull:
		return ReasonInventoryFull
	case mnet.ReasonUnknownNode:
		return ReasonUnknownNode
	case mnet.ReasonNodeDepleted:
		return ReasonNodeDepleted
	case mnet.ReasonNeedsClass:
		return ReasonNeedsClass
	case mnet.ReasonNoRecipe:
		return ReasonNoRecipe
	case mnet.ReasonMissingMat:
		return ReasonMissingMat
	case mnet.ReasonUnknownPlayer:
		return ReasonUnknownPlayer
	case mnet.ReasonSelf:
		return ReasonSelf
	case mnet.ReasonTargetDead:
		return ReasonTargetDead
	case mnet.ReasonNotDead:
		return ReasonNotDead
	case mnet.ReasonNoDialog:
		return ReasonNoDialog
	case mnet.ReasonUnknownOption:
		return ReasonUnknownOption
	case mnet.ReasonQuestActive:
		return ReasonQuestActive
	case mnet.ReasonQuestComplete:
		return ReasonQuestComplete
	case mnet.ReasonQuestInactive:
		return ReasonQuestInactive
	case mnet.ReasonQuestIncomplete:
		return ReasonQuestIncomplete
	case mnet.ReasonWrongItem:
		return ReasonWrongItem
	case mnet.ReasonNotLeader:
		return ReasonNotLeader
	case mnet.ReasonPartyFull:
		return ReasonPartyFull
	case mnet.ReasonAlreadyInParty:
		return ReasonAlreadyInParty
	case mnet.ReasonDuplicateInvite:
		return ReasonDuplicateInvite
	case mnet.ReasonNoInvite:
		return ReasonNoInvite
	case mnet.ReasonNotInParty:
		return ReasonNotInParty
	case mnet.ReasonNotSameParty:
		return ReasonNotSameParty
	case mnet.ReasonUnauthorized:
		return ReasonUnauthorized
	case mnet.ReasonUsage:
		return ReasonUsage
	case mnet.ReasonNonFinite:
		return ReasonNonFinite
	case mnet.ReasonOutOfBounds:
		return ReasonOutOfBounds
	default:
		panic(fmt.Sprintf("game: unmapped owner refusal %q", r))
	}
}

type BagEntry struct {
	Slot uint8
	Kind string
}
type WornEntry struct {
	Slot string
	Kind string
}
type SkillEntry struct {
	ID    string
	XP    int64
	Level uint32
}
type QuestEntry struct{ ID, Title, Objective, Status string }
type OwnerValue interface{ ownerValue() }
type InventoryValue struct {
	Size  uint8
	Slots []BagEntry
}

func (InventoryValue) ownerValue() {}

type EquipmentValue struct {
	Worn  []string
	Slots []WornEntry
}

func (EquipmentValue) ownerValue() {}

type ClassValue struct {
	ID           string
	MissingSlots []WornEntry
	MissingTools []string
}

func (ClassValue) ownerValue() {}

type SkillsValue struct{ Skills []SkillEntry }

func (SkillsValue) ownerValue() {}

type QuestLogValue struct{ Quests []QuestEntry }

func (QuestLogValue) ownerValue() {}

type DialogValue struct {
	NPC     NPCHandle
	Lines   []string
	Options []string
}

func (DialogValue) ownerValue() {}

type DialogClearValue struct{ NPC NPCHandle }

func (DialogClearValue) ownerValue() {}

type PartyValue struct {
	ID      uint64
	Leader  PlayerHandle
	Members []PlayerHandle
}

func (PartyValue) ownerValue() {}

type PartyClearValue struct{}

func (PartyClearValue) ownerValue() {}

type InviteValue struct{ From PlayerHandle }

func (InviteValue) ownerValue() {}

type InviteClearValue struct{}

func (InviteClearValue) ownerValue() {}

type AdminReplyValue struct{ Text string }

func (AdminReplyValue) ownerValue() {}

type CooldownValue struct {
	Ability   string
	ReadyTick uint32
}

func (CooldownValue) ownerValue() {}

type RefusedValue struct {
	Origin Origin
	Reason RefusalReason
}

func (RefusedValue) ownerValue() {}

type OwnerChange struct {
	Player PlayerHandle
	Tick   uint32
	Value  OwnerValue
}

func CloneOwnerValue(value OwnerValue) OwnerValue {
	switch v := value.(type) {
	case InventoryValue:
		v.Slots = slices.Clone(v.Slots)
		return v
	case EquipmentValue:
		v.Worn = slices.Clone(v.Worn)
		v.Slots = slices.Clone(v.Slots)
		return v
	case ClassValue:
		v.MissingSlots = slices.Clone(v.MissingSlots)
		v.MissingTools = slices.Clone(v.MissingTools)
		return v
	case SkillsValue:
		v.Skills = slices.Clone(v.Skills)
		return v
	case QuestLogValue:
		v.Quests = slices.Clone(v.Quests)
		return v
	case DialogValue:
		v.Lines = slices.Clone(v.Lines)
		v.Options = slices.Clone(v.Options)
		return v
	case PartyValue:
		v.Members = slices.Clone(v.Members)
		return v
	case DialogClearValue, PartyClearValue, InviteValue, InviteClearValue, AdminReplyValue, CooldownValue, RefusedValue:
		return value
	default:
		panic(fmt.Sprintf("game: unknown owner value %T", value))
	}
}
func (w *World) emitOwner(p *player, v OwnerValue) {
	if !p.domainOwned {
		return
	}
	w.ownerChanges = append(w.ownerChanges, OwnerChange{Player: PlayerHandle{uint32(p.id), 1}, Tick: uint32(w.tick), Value: CloneOwnerValue(v)})
}
func (w *World) TakeOwnerChanges() []OwnerChange {
	out := w.ownerChanges
	w.ownerChanges = nil
	return out
}
func (w *World) AdvanceTick() uint32 {
	if w.tick >= int64(^uint32(0)) {
		panic("game: tick exhausted")
	}
	w.step()
	return uint32(w.tick)
}
func (w *World) captureOwner(p *player, msg mnet.ServerMessage) {
	if !p.domainOwned {
		return
	}
	switch v := msg.(type) {
	case mnet.Inventory:
		out := InventoryValue{Size: uint8(v.Size)}
		for _, x := range v.Slots {
			out.Slots = append(out.Slots, BagEntry{uint8(x.Slot), x.Kind})
		}
		w.emitOwner(p, out)
	case mnet.Equipment:
		out := EquipmentValue{}
		for _, name := range v.Worn {
			out.Worn = append(out.Worn, string(name))
		}
		for _, x := range v.Slots {
			out.Slots = append(out.Slots, WornEntry{string(x.Slot), x.Kind})
		}
		w.emitOwner(p, out)
	case mnet.Class:
		out := ClassValue{ID: v.Class, MissingTools: v.Missing.Tools}
		for _, x := range v.Missing.Slots {
			out.MissingSlots = append(out.MissingSlots, WornEntry{x.Slot, x.Kind})
		}
		w.emitOwner(p, out)
	case mnet.Skills:
		out := SkillsValue{}
		for _, x := range v.Skills {
			out.Skills = append(out.Skills, SkillEntry{x.ID, x.XP, uint32(x.Level)})
		}
		w.emitOwner(p, out)
	case mnet.QuestLog:
		out := QuestLogValue{}
		for _, x := range v.Quests {
			out.Quests = append(out.Quests, QuestEntry{x.ID, x.Title, x.Objective, x.Status})
		}
		w.emitOwner(p, out)
	case mnet.Dialog:
		npc := NPCHandle{uint32(v.NPC), 1}
		if len(v.Lines) == 0 && len(v.Options) == 0 {
			w.emitOwner(p, DialogClearValue{npc})
			return
		}
		out := DialogValue{NPC: npc, Lines: v.Lines}
		for _, x := range v.Options {
			out.Options = append(out.Options, x.ID)
		}
		w.emitOwner(p, out)
	case mnet.Party:
		if v.ID == 0 {
			w.emitOwner(p, PartyClearValue{})
			return
		}
		out := PartyValue{ID: uint64(v.ID), Leader: PlayerHandle{uint32(v.Leader), 1}}
		for _, x := range v.Members {
			out.Members = append(out.Members, PlayerHandle{uint32(x), 1})
		}
		w.emitOwner(p, out)
	case mnet.PartyInviteNotice:
		if v.From == 0 {
			w.emitOwner(p, InviteClearValue{})
			return
		}
		w.emitOwner(p, InviteValue{PlayerHandle{uint32(v.From), 1}})
	case mnet.AdminReply:
		w.emitOwner(p, AdminReplyValue{v.Text})
	case mnet.Error:
		if v.Reason != "" {
			w.emitOwner(p, RefusedValue{p.origin, domainReason(v.Reason)})
		}
	}
}
