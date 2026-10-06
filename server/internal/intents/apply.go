package intents

import (
	"fmt"
	"github.com/devarminas/marque/server/internal/eventstream"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/wire"
)

func Admit(sessions *eventstream.Sessions, id eventstream.SessionID, epoch eventstream.Epoch, message wire.IntentsMsg) (game.Command, error) {
	owner, err := sessions.Resolve(id, epoch)
	if err != nil {
		return nil, err
	}
	if commit, ok := message.(wire.ApplicationCommit); ok {
		if eventstream.Epoch(commit.Epoch()) != epoch {
			return nil, eventstream.ErrEpoch
		}
		return nil, sessions.Commit(id, eventstream.Commit{Stream: eventstream.StreamID(commit.Stream()), Epoch: epoch, Tick: commit.Tick(), EventEnd: commit.EventEnd()})
	}
	seq, action, err := actionOf(message)
	if err != nil {
		return nil, err
	}
	canonical, err := message.Append(nil)
	if err != nil {
		return nil, err
	}
	admitted, err := sessions.AcceptIntent(id, epoch, seq, canonical)
	if err != nil || !admitted {
		return nil, err
	}
	return game.ActionCommand{Player: owner, Origin: game.Origin{Source: game.OriginIntent, Seq: seq}, Action: action}, nil
}
func AdmitInput(sessions *eventstream.Sessions, id eventstream.SessionID, epoch eventstream.Epoch, message wire.Input) (game.Command, error) {
	owner, err := sessions.Resolve(id, epoch)
	if err != nil {
		return nil, err
	}
	accepted, err := sessions.AcceptInput(id, epoch, message.Seq())
	if err != nil || !accepted {
		return nil, err
	}
	return game.InputCommand{Player: owner, Origin: game.Origin{Source: game.OriginInput, Seq: message.Seq()}, DX: message.Dx(), DZ: message.Dz(), Jump: message.Jump()}, nil
}
func Apply(world *game.World, sessions *eventstream.Sessions, id eventstream.SessionID, epoch eventstream.Epoch, message wire.IntentsMsg) error {
	command, err := Admit(sessions, id, epoch, message)
	if err != nil || command == nil {
		return err
	}
	c := command.(game.ActionCommand)
	return world.ApplyAction(c.Player, c.Origin, c.Action)
}
func ApplyInput(world *game.World, sessions *eventstream.Sessions, id eventstream.SessionID, epoch eventstream.Epoch, message wire.Input) error {
	command, err := AdmitInput(sessions, id, epoch, message)
	if err != nil || command == nil {
		return err
	}
	c := command.(game.InputCommand)
	return world.ApplyInput(c.Player, c.Origin, c.DX, c.DZ, c.Jump)
}
func player(v wire.PlayerId) game.PlayerHandle { return game.PlayerHandle{Index: v.Index, Gen: v.Gen} }
func npc(v wire.NpcId) game.NPCHandle          { return game.NPCHandle{Index: v.Index, Gen: v.Gen} }
func actionOf(message wire.IntentsMsg) (uint32, game.Action, error) {
	switch v := message.(type) {
	case wire.Pickup:
		return v.Seq(), game.PickupAction{Item: game.ItemHandle{Index: v.Item().Index, Gen: v.Item().Gen}}, nil
	case wire.Drop:
		return v.Seq(), game.DropAction{Slot: v.Slot()}, nil
	case wire.Equip:
		return v.Seq(), game.EquipAction{Slot: v.Slot()}, nil
	case wire.Unequip:
		return v.Seq(), game.UnequipAction{Worn: v.Worn()}, nil
	case wire.Gather:
		return v.Seq(), game.GatherAction{Node: game.NodeHandle{Index: v.Node().Index, Gen: v.Node().Gen}}, nil
	case wire.UseSelf:
		return v.Seq(), game.UseSelfAction{Slot: v.Slot()}, nil
	case wire.AttackPlayer:
		return v.Seq(), game.AttackPlayerAction{Target: player(v.Target())}, nil
	case wire.Respawn:
		return v.Seq(), game.RespawnAction{}, nil
	case wire.CastSelf:
		return v.Seq(), game.CastSelfAction{Ability: v.Ability()}, nil
	case wire.Talk:
		return v.Seq(), game.TalkAction{NPC: npc(v.Npc())}, nil
	case wire.DialogOption:
		return v.Seq(), game.DialogOptionAction{NPC: npc(v.Npc()), Option: v.Option()}, nil
	case wire.Give:
		return v.Seq(), game.GiveAction{NPC: npc(v.Npc()), Slot: v.Slot()}, nil
	case wire.PartyInvite:
		return v.Seq(), game.PartyInviteAction{Player: player(v.Player())}, nil
	case wire.PartyAccept:
		return v.Seq(), game.PartyAcceptAction{}, nil
	case wire.PartyDecline:
		return v.Seq(), game.PartyDeclineAction{}, nil
	case wire.PartyLeave:
		return v.Seq(), game.PartyLeaveAction{}, nil
	case wire.PartyKick:
		return v.Seq(), game.PartyKickAction{Player: player(v.Player())}, nil
	case wire.Admin:
		return v.Seq(), game.AdminAction{Line: v.Line()}, nil
	case wire.UseStation:
		return v.Seq(), game.UseStationAction{Slot: v.Slot(), Node: game.NodeHandle{Index: v.Node().Index, Gen: v.Node().Gen}}, nil
	case wire.AttackNpc:
		return v.Seq(), game.AttackNPCAction{Target: npc(v.Target())}, nil
	case wire.CastPlayer:
		return v.Seq(), game.CastPlayerAction{Ability: v.Ability(), Target: player(v.Target())}, nil
	case wire.CastNpc:
		return v.Seq(), game.CastNPCAction{Ability: v.Ability(), Target: npc(v.Target())}, nil
	default:
		return 0, nil, fmt.Errorf("intents: unsupported message %T", message)
	}
}
