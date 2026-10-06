package game

import (
	"errors"
	"fmt"
	mnet "github.com/devarminas/marque/server/internal/net"
)

type Action interface{ gameAction() }
type PickupAction struct{ Item ItemHandle }

func (PickupAction) gameAction() {}

type DropAction struct{ Slot uint8 }

func (DropAction) gameAction() {}

type EquipAction struct{ Slot uint8 }

func (EquipAction) gameAction() {}

type UnequipAction struct{ Worn string }

func (UnequipAction) gameAction() {}

type GatherAction struct{ Node NodeHandle }

func (GatherAction) gameAction() {}

type UseSelfAction struct{ Slot uint8 }

func (UseSelfAction) gameAction() {}

type AttackPlayerAction struct{ Target PlayerHandle }

func (AttackPlayerAction) gameAction() {}

type AttackNPCAction struct{ Target NPCHandle }

func (AttackNPCAction) gameAction() {}

type RespawnAction struct{}

func (RespawnAction) gameAction() {}

type CastSelfAction struct{ Ability string }

func (CastSelfAction) gameAction() {}

type CastPlayerAction struct {
	Ability string
	Target  PlayerHandle
}

func (CastPlayerAction) gameAction() {}

type CastNPCAction struct {
	Ability string
	Target  NPCHandle
}

func (CastNPCAction) gameAction() {}

type TalkAction struct{ NPC NPCHandle }

func (TalkAction) gameAction() {}

type DialogOptionAction struct {
	NPC    NPCHandle
	Option string
}

func (DialogOptionAction) gameAction() {}

type GiveAction struct {
	NPC  NPCHandle
	Slot uint8
}

func (GiveAction) gameAction() {}

type PartyInviteAction struct{ Player PlayerHandle }

func (PartyInviteAction) gameAction() {}

type PartyAcceptAction struct{}

func (PartyAcceptAction) gameAction() {}

type PartyDeclineAction struct{}

func (PartyDeclineAction) gameAction() {}

type PartyLeaveAction struct{}

func (PartyLeaveAction) gameAction() {}

type PartyKickAction struct{ Player PlayerHandle }

func (PartyKickAction) gameAction() {}

type AdminAction struct{ Line string }

func (AdminAction) gameAction() {}

type UseStationAction struct {
	Slot uint8
	Node NodeHandle
}

func (UseStationAction) gameAction() {}

type combatTargetKind uint8

const (
	legacyCombatTarget combatTargetKind = iota
	playerCombatTargetKind
	npcCombatTargetKind
)

type combatTargetHandle struct {
	kind combatTargetKind
	gen  uint32
}

func (w *World) validCombatTarget(id mnet.PlayerID, h combatTargetHandle) bool {
	if h.kind == legacyCombatTarget {
		return true
	}
	if h.gen != 1 {
		return false
	}
	switch h.kind {
	case playerCombatTargetKind:
		return w.players[id] != nil
	case npcCombatTargetKind:
		return w.npcs[id] != nil
	}
	return false
}

var ErrOwner = errors.New("game: unknown owner handle")

func (w *World) CreateOwner() (PlayerHandle, error) {
	if w.nextID+1 >= practiceNpcIDBand {
		return PlayerHandle{}, ErrOwner
	}
	p := w.initializePlayer(nil)
	p.domainOwned = true
	w.seedJoinKit(p)
	w.sendJoinStep(p)
	return PlayerHandle{uint32(p.id), 1}, nil
}
func (w *World) ReleaseOwner(h PlayerHandle) error {
	p := w.players[mnet.PlayerID(h.Index)]
	if h.Gen != 1 || p == nil || !p.domainOwned {
		return ErrOwner
	}
	w.retire(p)
	return nil
}
func (w *World) ApplyInput(h PlayerHandle, origin Origin, dx, dz float64, jump bool) error {
	return w.applyInput(h, origin, dx, dz, jump)
}
func (w *World) applyInput(h PlayerHandle, origin Origin, dx, dz float64, jump bool) error {
	if origin.Source != OriginInput {
		return errors.New("game: input origin required")
	}
	p := w.players[mnet.PlayerID(h.Index)]
	if h.Gen != 1 || p == nil {
		return ErrOwner
	}
	previous := p.origin
	p.origin = origin
	defer func() { p.origin = previous }()
	if origin.Seq > p.inputSeq {
		p.inputSeq = origin.Seq
	}
	if !w.refuseIfDead(p, mnet.MsgMove) {
		w.move(p, mnet.Move{DX: dx, DZ: dz, Jump: jump}, mnet.Seq(origin.Seq))
	}
	return nil
}
func (w *World) ApplyAction(h PlayerHandle, origin Origin, action Action) error {
	return w.applyAction(h, origin, action)
}
func (w *World) applyAction(h PlayerHandle, origin Origin, action Action) error {
	if origin.Source != OriginIntent {
		return errors.New("game: intent origin required")
	}
	p := w.players[mnet.PlayerID(h.Index)]
	if h.Gen != 1 || p == nil {
		return ErrOwner
	}
	previous := p.origin
	p.origin = origin
	defer func() { p.origin = previous }()
	switch a := action.(type) {
	case PickupAction:
		if a.Item.Gen != 1 {
			w.refuse(p, &mnet.RejectError{Reason: mnet.ReasonUnknownItem, Detail: "stale handle", Re: mnet.MsgPickup, Disposition: mnet.ReplyError})
			return nil
		}
		if !w.refuseIfDead(p, mnet.MsgPickup) {
			w.pickup(p, mnet.Pickup{Item: mnet.ItemID(a.Item.Index)}, mnet.Seq(origin.Seq))
		}
		return nil
	case DropAction:
		if !w.refuseIfDead(p, mnet.MsgDrop) {
			w.drop(p, mnet.Drop{Slot: int(a.Slot)}, mnet.Seq(origin.Seq))
		}
		return nil
	case EquipAction:
		if !w.refuseIfDead(p, mnet.MsgEquip) {
			w.equip(p, mnet.Equip{Slot: int(a.Slot)}, mnet.Seq(origin.Seq))
		}
		return nil
	case UnequipAction:
		if !w.refuseIfDead(p, mnet.MsgUnequip) {
			w.unequip(p, mnet.Unequip{Worn: mnet.EquipSlot(a.Worn)}, mnet.Seq(origin.Seq))
		}
		return nil
	case GatherAction:
		if a.Node.Gen != 1 {
			w.refuse(p, &mnet.RejectError{Reason: mnet.ReasonUnknownNode, Detail: "stale handle", Re: mnet.MsgGather, Disposition: mnet.ReplyError})
			return nil
		}
		if !w.refuseIfDead(p, mnet.MsgGather) {
			w.gather(p, mnet.Gather{Node: mnet.NodeID(a.Node.Index)}, mnet.Seq(origin.Seq))
		}
		return nil
	case UseSelfAction:
		if !w.refuseIfDead(p, mnet.MsgUse) {
			w.use(p, mnet.Use{Slot: int(a.Slot), On: int(a.Slot)}, mnet.Seq(origin.Seq))
		}
		return nil
	case AttackPlayerAction:
		w.attackWithTarget(p, mnet.Attack{Player: mnet.PlayerID(a.Target.Index)}, mnet.Seq(origin.Seq), combatTargetHandle{kind: playerCombatTargetKind, gen: a.Target.Gen})
		return nil
	case AttackNPCAction:
		w.attackWithTarget(p, mnet.Attack{Player: mnet.PlayerID(a.Target.Index)}, mnet.Seq(origin.Seq), combatTargetHandle{kind: npcCombatTargetKind, gen: a.Target.Gen})
		return nil
	case RespawnAction:
		w.respawnPlayer(p, mnet.Seq(origin.Seq))
		return nil
	case CastSelfAction:
		w.cast(p, mnet.Cast{Ability: a.Ability}, mnet.Seq(origin.Seq))
		return nil
	case CastPlayerAction:
		w.castWithTarget(p, mnet.Cast{Ability: a.Ability, Player: mnet.PlayerID(a.Target.Index)}, mnet.Seq(origin.Seq), combatTargetHandle{kind: playerCombatTargetKind, gen: a.Target.Gen})
		return nil
	case CastNPCAction:
		w.castWithTarget(p, mnet.Cast{Ability: a.Ability, Player: mnet.PlayerID(a.Target.Index)}, mnet.Seq(origin.Seq), combatTargetHandle{kind: npcCombatTargetKind, gen: a.Target.Gen})
		return nil
	case TalkAction:
		if a.NPC.Gen != 1 {
			w.refuse(p, &mnet.RejectError{Reason: mnet.ReasonUnknownPlayer, Detail: "stale handle", Re: mnet.MsgTalk, Disposition: mnet.ReplyError})
			return nil
		}
		if !w.refuseIfDead(p, mnet.MsgTalk) {
			w.talk(p, mnet.Talk{NPC: mnet.PlayerID(a.NPC.Index)}, mnet.Seq(origin.Seq))
		}
		return nil
	case DialogOptionAction:
		if a.NPC.Gen != 1 {
			w.refuse(p, &mnet.RejectError{Reason: mnet.ReasonUnknownPlayer, Detail: "stale handle", Re: mnet.MsgDialogOption, Disposition: mnet.ReplyError})
			return nil
		}
		if !w.refuseIfDead(p, mnet.MsgDialogOption) {
			w.dialogOption(p, mnet.DialogOptionPick{NPC: mnet.PlayerID(a.NPC.Index), Option: a.Option}, mnet.Seq(origin.Seq))
		}
		return nil
	case GiveAction:
		if a.NPC.Gen != 1 {
			w.refuse(p, &mnet.RejectError{Reason: mnet.ReasonUnknownPlayer, Detail: "stale handle", Re: mnet.MsgGive, Disposition: mnet.ReplyError})
			return nil
		}
		if !w.refuseIfDead(p, mnet.MsgGive) {
			w.give(p, mnet.Give{NPC: mnet.PlayerID(a.NPC.Index), Slot: int(a.Slot)}, mnet.Seq(origin.Seq))
		}
		return nil
	case PartyInviteAction:
		if a.Player.Gen != 1 {
			w.refuse(p, &mnet.RejectError{Reason: mnet.ReasonUnknownPlayer, Detail: "stale handle", Re: mnet.MsgPartyInvite, Disposition: mnet.ReplyError})
			return nil
		}
		w.partyInvite(p, mnet.PartyInvite{Player: mnet.PlayerID(a.Player.Index)}, mnet.Seq(origin.Seq))
		return nil
	case PartyAcceptAction:
		w.partyAccept(p, mnet.PartyAccept{}, mnet.Seq(origin.Seq))
		return nil
	case PartyDeclineAction:
		w.partyDecline(p, mnet.PartyDecline{}, mnet.Seq(origin.Seq))
		return nil
	case PartyLeaveAction:
		w.partyLeave(p, mnet.PartyLeave{}, mnet.Seq(origin.Seq))
		return nil
	case PartyKickAction:
		if a.Player.Gen != 1 {
			w.refuse(p, &mnet.RejectError{Reason: mnet.ReasonUnknownPlayer, Detail: "stale handle", Re: mnet.MsgPartyKick, Disposition: mnet.ReplyError})
			return nil
		}
		w.partyKick(p, mnet.PartyKick{Player: mnet.PlayerID(a.Player.Index)}, mnet.Seq(origin.Seq))
		return nil
	case AdminAction:
		w.admin(p, mnet.Admin{Line: a.Line}, mnet.Seq(origin.Seq))
		return nil
	case UseStationAction:
		if w.refuseIfDead(p, mnet.MsgUse) {
			return nil
		}
		if a.Node.Gen != 1 {
			w.refuse(p, &mnet.RejectError{Reason: mnet.ReasonNoRecipe, Detail: "stale station", Re: mnet.MsgUse, Disposition: mnet.ReplyError})
			return nil
		}
		w.useOnStation(p, mnet.Use{Slot: int(a.Slot), On: int(a.Node.Index)}, mnet.Seq(origin.Seq))
		return nil
	default:
		return fmt.Errorf("game: unknown action %T", action)
	}
}
