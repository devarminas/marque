package game

import (
	"errors"
	"fmt"
	"math"
)

type Command interface{ gameCommand() }
type ActionCommand struct {
	Player PlayerHandle
	Origin Origin
	Action Action
}

func (ActionCommand) gameCommand() {}

type InputCommand struct {
	Player PlayerHandle
	Origin Origin
	DX, DZ float64
	Jump   bool
}

func (InputCommand) gameCommand() {}

type CreateOwnerCommand struct{ Request uint64 }

func (CreateOwnerCommand) gameCommand() {}

type ReleaseOwnerCommand struct{ Player PlayerHandle }

func (ReleaseOwnerCommand) gameCommand() {}

type OwnerCreated struct {
	Request uint64
	Player  PlayerHandle
}
type TickBatch struct {
	Tick          uint32
	OwnerChanges  []OwnerChange
	Presentations []Presentation
	Created       []OwnerCreated
	Released      []PlayerHandle
	Frame         StateFrame
}

var ErrTickExhausted = errors.New("game: tick horizon exhausted")

var ErrPendingChanges = errors.New("game: pending legacy owner changes must be consumed before Step")

func (w *World) Step(commands []Command) (TickBatch, error) {
	if w.transaction != nil {
		return TickBatch{}, errors.New("game: nested Step")
	}
	if err := w.validateTickHorizon(); err != nil {
		return TickBatch{}, err
	}
	if len(w.ownerChanges) != 0 {
		return TickBatch{}, ErrPendingChanges
	}
	live := make(map[PlayerHandle]bool, len(w.players))
	for _, p := range w.order {
		if p.domainOwned {
			live[PlayerHandle{uint32(p.id), 1}] = true
		}
	}
	creates := int64(0)
	requests := map[uint64]bool{}
	for _, command := range commands {
		switch c := command.(type) {
		case ActionCommand:
			if !live[c.Player] {
				return TickBatch{}, ErrOwner
			}
			if c.Origin.Source != OriginIntent || !validAction(c.Action) {
				return TickBatch{}, errors.New("game: invalid action command")
			}
		case InputCommand:
			if !live[c.Player] {
				return TickBatch{}, ErrOwner
			}
			if c.Origin.Source != OriginInput || math.IsNaN(c.DX) || math.IsNaN(c.DZ) || math.IsInf(c.DX, 0) || math.IsInf(c.DZ, 0) || math.Abs(c.DX) > 1 || math.Abs(c.DZ) > 1 {
				return TickBatch{}, errors.New("game: invalid input command")
			}
		case CreateOwnerCommand:
			if requests[c.Request] {
				return TickBatch{}, errors.New("game: duplicate owner request")
			}
			requests[c.Request] = true
			creates++
			if int64(w.nextID)+creates >= int64(practiceNpcIDBand) {
				return TickBatch{}, ErrOwner
			}
		case ReleaseOwnerCommand:
			if !live[c.Player] {
				return TickBatch{}, ErrOwner
			}
			delete(live, c.Player)
		default:
			return TickBatch{}, fmt.Errorf("game: unknown command %T", command)
		}
	}
	if err := w.reserveTickHandles(commands); err != nil {
		return TickBatch{}, err
	}
	batch := TickBatch{Tick: uint32(w.tick + 1)}
	w.transaction = &batch
	defer func() { w.transaction = nil }()
	for _, command := range commands {
		var err error
		switch c := command.(type) {
		case ActionCommand:
			c.Origin.Action = kindOfAction(c.Action)
			err = w.applyAction(c.Player, c.Origin, c.Action)
		case InputCommand:
			err = w.applyInput(c.Player, c.Origin, c.DX, c.DZ, c.Jump)
		case CreateOwnerCommand:
			var h PlayerHandle
			h, err = w.CreateOwner()
			batch.Created = append(batch.Created, OwnerCreated{c.Request, h})
		case ReleaseOwnerCommand:
			err = w.ReleaseOwner(c.Player)
			batch.Released = append(batch.Released, c.Player)
		}
		if err != nil {
			panic(fmt.Sprintf("game: prevalidated command failed: %v", err))
		}
	}
	w.step()
	batch.Frame = w.stateFrame()
	return batch, nil
}

func validAction(action Action) bool {
	switch action.(type) {
	case PickupAction, DropAction, EquipAction, UnequipAction, GatherAction, UseSelfAction, AttackPlayerAction, AttackNPCAction, RespawnAction, CastSelfAction, CastPlayerAction, CastNPCAction, TalkAction, DialogOptionAction, GiveAction, PartyInviteAction, PartyAcceptAction, PartyDeclineAction, PartyLeaveAction, PartyKickAction, AdminAction, UseStationAction:
		return true
	}
	return false
}

func (w *World) producingTick() uint32 {
	if w.transaction != nil {
		return w.transaction.Tick
	}
	return uint32(w.tick)
}

func (w *World) validateTickHorizon() error {
	if w.tick < 0 || w.tick >= math.MaxUint32-1 {
		return ErrTickExhausted
	}
	next := uint64(w.tick + 1)
	if w.abilities != nil {
		for _, id := range w.abilities.IDs() {
			a, _ := w.abilities.Get(id)
			if uint64(a.CastTicks) >= math.MaxUint32-next || uint64(a.CooldownTicks) >= math.MaxUint32-next-uint64(a.CastTicks) {
				return ErrTickExhausted
			}
		}
	}
	for _, p := range w.order {
		if p.casting() && uint64(p.castTotal-p.castProgress) >= math.MaxUint32-next {
			return ErrTickExhausted
		}
		for _, ready := range p.cooldowns.readyAt {
			if ready < 0 || ready > math.MaxUint32 {
				return ErrTickExhausted
			}
		}
	}
	for _, n := range w.npcs {
		if n.casting() && uint64(n.castTotal-n.castProgress) >= math.MaxUint32-next {
			return ErrTickExhausted
		}
	}
	return nil
}

func (w *World) reserveTickHandles(commands []Command) error {
	var items, npcs uint64
	for _, command := range commands {
		if c, ok := command.(ActionCommand); ok {
			switch a := c.Action.(type) {
			case DropAction:
				items++
			case AdminAction:
				name, _, err := ParseAdminLine(a.Line)
				if err == nil && name == "spawn" {
					npcs++
				}
			}
		}
	}
	if items > w.items.GroundItemCapacity() {
		return ErrItemHandlesExhausted
	}
	for _, c := range w.camps {
		var due uint64
		for _, tick := range c.pending {
			if tick <= w.tick+1 {
				due++
			}
		}
		if c.content.DeathTimerTicks <= 1 {
			due += uint64(w.campLiveCount(c))
		}
		npcs += min(due, uint64(c.content.PoolMax))
	}
	if npcs > w.npcHandleCapacity() {
		return ErrNPCHandlesExhausted
	}
	return nil
}
