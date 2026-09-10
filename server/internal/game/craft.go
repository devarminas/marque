package game

import (
	"errors"
	"fmt"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const KindSticks = "sticks"

func (w *World) use(p *player, msg mnet.Use, seq mnet.Seq) {
	if msg.On != msg.Slot {
		w.useOnStation(p, msg, seq)
		return
	}

	done, err := w.items.CraftInventorySlot(p.id, msg.Slot, KindLogs, KindSticks)
	if err != nil {
		w.refuseCraft(p, msg.Slot, err)
		return
	}

	w.log.Event(w.tick, EvUse, withSeq(gamelog.Fields{
		"player": p.id,
		"slot":   msg.Slot,
		"on":     msg.On,
		"from":   done.Consume,
		"to":     done.Produce,
	}, seq))

	w.sendInventory(p)
}

func (w *World) refuseCraft(p *player, slot int, err error) {
	switch {
	case errors.Is(err, ErrNoSuchSlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoSuchSlot,
			Detail:      fmt.Sprintf("no such slot: %d is outside 0 to %d", slot, InventorySize-1),
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
	case errors.Is(err, ErrEmptySlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonEmptySlot,
			Detail:      "that slot is empty",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
	case errors.Is(err, ErrNoRecipe):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoRecipe,
			Detail:      "that cannot be crafted",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
	case errors.Is(err, ErrInventoryFull):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonInventoryFull,
			Detail:      "inventory is full",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
	default:
		panic(fmt.Sprintf("game: crafting slot %d for player %d: %v", slot, p.id, err))
	}
}
