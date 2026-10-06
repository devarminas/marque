package game

type ActionKind uint8

const (
	ActionPickup ActionKind = iota + 1
	ActionDrop
	ActionEquip
	ActionUnequip
	ActionGather
	ActionUseSelf
	ActionAttackPlayer
	ActionAttackNPC
	ActionRespawn
	ActionCastSelf
	ActionCastPlayer
	ActionCastNPC
	ActionTalk
	ActionDialogOption
	ActionGive
	ActionPartyInvite
	ActionPartyAccept
	ActionPartyDecline
	ActionPartyLeave
	ActionPartyKick
	ActionAdmin
	ActionUseStation
)

func kindOfAction(action Action) ActionKind {
	switch action.(type) {
	case PickupAction:
		return ActionPickup
	case DropAction:
		return ActionDrop
	case EquipAction:
		return ActionEquip
	case UnequipAction:
		return ActionUnequip
	case GatherAction:
		return ActionGather
	case UseSelfAction:
		return ActionUseSelf
	case AttackPlayerAction:
		return ActionAttackPlayer
	case AttackNPCAction:
		return ActionAttackNPC
	case RespawnAction:
		return ActionRespawn
	case CastSelfAction:
		return ActionCastSelf
	case CastPlayerAction:
		return ActionCastPlayer
	case CastNPCAction:
		return ActionCastNPC
	case TalkAction:
		return ActionTalk
	case DialogOptionAction:
		return ActionDialogOption
	case GiveAction:
		return ActionGive
	case PartyInviteAction:
		return ActionPartyInvite
	case PartyAcceptAction:
		return ActionPartyAccept
	case PartyDeclineAction:
		return ActionPartyDecline
	case PartyLeaveAction:
		return ActionPartyLeave
	case PartyKickAction:
		return ActionPartyKick
	case AdminAction:
		return ActionAdmin
	case UseStationAction:
		return ActionUseStation
	}
	return 0
}
