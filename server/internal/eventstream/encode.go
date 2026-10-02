package eventstream

import (
	"fmt"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/wire"
)

func built[M wire.Message](message M, err error) ([]byte, error) {
	if err != nil {
		return nil, err
	}
	return message.Append(nil)
}
func encode(stream, seq uint64, tick uint32, value game.OwnerValue) ([]byte, error) {
	switch v := value.(type) {
	case game.InventoryValue:
		f := wire.InventoryFields{Stream: stream, EventSeq: seq, Tick: tick, Size: v.Size}
		for _, x := range v.Slots {
			e, err := wire.BagEntryFields{Slot: x.Slot, Kind: x.Kind}.Build()
			if err != nil {
				return nil, err
			}
			f.Slots = append(f.Slots, e)
		}
		return built(f.Build())
	case game.EquipmentValue:
		f := wire.EquipmentFields{Stream: stream, EventSeq: seq, Tick: tick}
		for _, name := range v.Worn {
			entry, err := wire.WornNameFields{Name: name}.Build()
			if err != nil {
				return nil, err
			}
			f.Worn = append(f.Worn, entry)
		}
		for _, x := range v.Slots {
			e, err := wire.WornEntryFields{Slot: x.Slot, Kind: x.Kind}.Build()
			if err != nil {
				return nil, err
			}
			f.Slots = append(f.Slots, e)
		}
		return built(f.Build())
	case game.SkillsValue:
		f := wire.SkillsFields{Stream: stream, EventSeq: seq, Tick: tick}
		for _, x := range v.Skills {
			e, err := wire.SkillEntryFields{Id: x.ID, Xp: x.XP, Level: x.Level}.Build()
			if err != nil {
				return nil, err
			}
			f.Skills = append(f.Skills, e)
		}
		return built(f.Build())
	case game.QuestLogValue:
		f := wire.QuestLogFields{Stream: stream, EventSeq: seq, Tick: tick}
		for _, x := range v.Quests {
			e, err := wire.QuestEntryFields{Id: x.ID, Title: x.Title, Objective: x.Objective, Status: x.Status}.Build()
			if err != nil {
				return nil, err
			}
			f.Quests = append(f.Quests, e)
		}
		return built(f.Build())
	case game.ClassValue:
		f := wire.ClassFields{Stream: stream, EventSeq: seq, Tick: tick, ClassId: v.ID}
		for _, x := range v.MissingSlots {
			e, err := wire.WornEntryFields{Slot: x.Slot, Kind: x.Kind}.Build()
			if err != nil {
				return nil, err
			}
			f.MissingSlots = append(f.MissingSlots, e)
		}
		for _, x := range v.MissingTools {
			e, err := wire.ToolEntryFields{Kind: x}.Build()
			if err != nil {
				return nil, err
			}
			f.MissingTools = append(f.MissingTools, e)
		}
		return built(f.Build())
	case game.DialogValue:
		f := wire.DialogFields{Stream: stream, EventSeq: seq, Tick: tick, Npc: wire.NpcId{Index: v.NPC.Index, Gen: v.NPC.Gen}}
		for _, x := range v.Lines {
			e, err := wire.TextLineFields{Text: x}.Build()
			if err != nil {
				return nil, err
			}
			f.Lines = append(f.Lines, e)
		}
		for _, x := range v.Options {
			e, err := wire.DialogChoiceFields{Id: x}.Build()
			if err != nil {
				return nil, err
			}
			f.Options = append(f.Options, e)
		}
		return built(f.Build())
	case game.PartyValue:
		f := wire.PartyFields{Stream: stream, EventSeq: seq, Tick: tick, Id: v.ID, Leader: wire.PlayerId{Index: v.Leader.Index, Gen: v.Leader.Gen}}
		for _, x := range v.Members {
			f.Members = append(f.Members, wire.PlayerId{Index: x.Index, Gen: x.Gen})
		}
		return built(f.Build())
	case game.InviteValue:
		return built(wire.InviteFields{Stream: stream, EventSeq: seq, Tick: tick, From: wire.PlayerId{Index: v.From.Index, Gen: v.From.Gen}}.Build())
	case game.AdminReplyValue:
		return built(wire.AdminReplyFields{Stream: stream, EventSeq: seq, Tick: tick, Text: v.Text}.Build())
	case game.CooldownValue:
		return built(wire.CooldownFields{Stream: stream, EventSeq: seq, Tick: tick, Ability: v.Ability, ReadyTick: v.ReadyTick}.Build())
	case game.RefusedValue:
		return built(wire.RefusedFields{Stream: stream, EventSeq: seq, Tick: tick, Source: wire.OriginSource(v.Origin.Source), Seq: v.Origin.Seq, Reason: wire.RefuseReason(v.Reason)}.Build())
	case game.DialogClearValue:
		return built(wire.DialogClearFields{Stream: stream, EventSeq: seq, Tick: tick, Npc: wire.NpcId{Index: v.NPC.Index, Gen: v.NPC.Gen}}.Build())
	case game.PartyClearValue:
		return built(wire.PartyClearFields{Stream: stream, EventSeq: seq, Tick: tick}.Build())
	case game.InviteClearValue:
		return built(wire.InviteClearFields{Stream: stream, EventSeq: seq, Tick: tick}.Build())
	default:
		return nil, fmt.Errorf("eventstream: unknown owner value %T", value)
	}
}
