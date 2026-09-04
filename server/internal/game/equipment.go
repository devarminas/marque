package game

// Worn equipment: the two intents that move an item between the bag and a worn
// slot, and the restatement that tells one player what it is wearing.
// PROTOCOL.md, "Equipment", is the contract.

import (
	"errors"
	"fmt"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func (w *World) equip(p *player, msg mnet.Equip, seq mnet.Seq) {
	done, err := w.items.EquipInventorySlot(p.id, msg.Slot)
	switch {
	case errors.Is(err, ErrNoSuchSlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoSuchSlot,
			Detail:      fmt.Sprintf("no such slot: %d is outside 0 to %d", msg.Slot, InventorySize-1),
			Re:          mnet.MsgEquip,
			Disposition: mnet.ReplyError,
		})
		return
	case errors.Is(err, ErrEmptySlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonEmptySlot,
			Detail:      "that slot is empty",
			Re:          mnet.MsgEquip,
			Disposition: mnet.ReplyError,
		})
		return
	case errors.Is(err, ErrNotEquippable):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNotEquippable,
			Detail:      "that cannot be worn",
			Re:          mnet.MsgEquip,
			Disposition: mnet.ReplyError,
		})
		return
	case err != nil:
		panic(fmt.Sprintf("game: equipping slot %d for player %d: %v", msg.Slot, p.id, err))
	}

	fields := gamelog.Fields{
		"player": p.id,
		"slot":   done.Bag,
		"kind":   done.Kind,
		"worn":   string(done.Worn),
	}
	if done.Displaced != "" {
		fields["displaced"] = done.Displaced
	}
	w.log.Event(w.tick, EvEquip, withSeq(fields, seq))

	w.sendInventory(p)
	w.sendEquipment(p)
}

func (w *World) unequip(p *player, msg mnet.Unequip, seq mnet.Seq) {
	done, err := w.items.UnequipWornSlot(p.id, msg.Worn)
	switch {
	case errors.Is(err, ErrNoSuchWornSlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoSuchWornSlot,
			Detail:      fmt.Sprintf("no such worn slot: %q", msg.Worn),
			Re:          mnet.MsgUnequip,
			Disposition: mnet.ReplyError,
		})
		return
	case errors.Is(err, ErrEmptyWornSlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonEmptyWornSlot,
			Detail:      "that worn slot is empty",
			Re:          mnet.MsgUnequip,
			Disposition: mnet.ReplyError,
		})
		return
	case errors.Is(err, ErrInventoryFull):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonInventoryFull,
			Detail:      "inventory is full",
			Re:          mnet.MsgUnequip,
			Disposition: mnet.ReplyError,
		})
		return
	case err != nil:
		panic(fmt.Sprintf("game: unequipping %q for player %d: %v", msg.Worn, p.id, err))
	}

	w.log.Event(w.tick, EvUnequip, withSeq(gamelog.Fields{
		"player": p.id,
		"worn":   string(done.Worn),
		"kind":   done.Kind,
		"slot":   done.Bag,
	}, seq))

	w.sendInventory(p)
	w.sendEquipment(p)
}

// seedJoinKit gives a joining player its starting items. It runs before the
// welcome step, so the first inventory the client sees already carries them.
func (w *World) seedJoinKit(p *player) {
	for _, kind := range w.joinKit {
		slot, err := w.items.SpawnInventoryItem(p.id, kind)
		if err != nil {
			panic(fmt.Sprintf("game: seeding %q for joining player %d: %v", kind, p.id, err))
		}
		w.log.Event(w.tick, EvJoinSeeded, gamelog.Fields{
			"player": p.id,
			"kind":   kind,
			"slot":   slot.Index,
		})
	}
}

func (w *World) sendEquipment(p *player) {
	occupied := w.items.Worn(p.id)
	slots := make([]mnet.EquipmentSlot, 0, len(occupied))
	for _, s := range occupied {
		slots = append(slots, mnet.EquipmentSlot{Slot: s.Slot, Kind: s.Kind})
	}
	w.send(p, mnet.Equipment{Worn: WornSlots, Slots: slots})
}
