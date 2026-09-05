package game

import (
	"errors"
	"fmt"
	"math"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// PickupRange is how near a player must be to a ground item to take it, in
// world units. It governs resolution only, never path assignment.
// Tuning: ARM-26.
const PickupRange = 0.5

// SeedGroundItem puts one item into the world before it opens. It must be
// called before Run, and fails when the coordinate is outside the world.
func (w *World) SeedGroundItem(kind string, x, z float64) error {
	if kind == "" {
		return errors.New("seed item: kind must not be empty")
	}
	if reason, detail := checkCoordinates(x, z); reason != "" {
		return fmt.Errorf("seed item %q at (%v, %v): %s", kind, x, z, detail)
	}
	w.noteItemEntered(w.items.SpawnGroundItem(kind, x, z))
	return nil
}

func (w *World) noteItemEntered(item GroundItem) {
	w.log.Event(w.tick, EvItemSpawned, itemLogFields(item))
}

func (w *World) pickup(p *player, msg mnet.Pickup, seq mnet.Seq) {
	w.log.Event(w.tick, EvPickup, withSeq(playerItemFields(p.id, msg.Item), seq))

	item, live := w.items.GroundItem(msg.Item)
	if !live {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownItem,
			Detail:      "no such item",
			Re:          mnet.MsgPickup,
			Disposition: mnet.ReplyError,
		})
		return
	}

	p.pending = item.ID
	w.cancelGather(p)
	w.cancelAttack(p, CausePickup)

	points, assign := destinationPath(p, Point{X: item.X, Z: item.Z})
	if !assign {
		return
	}
	w.assignPath(p, points)
}

func (w *World) drop(p *player, msg mnet.Drop, seq mnet.Seq) {
	item, err := w.items.DropInventorySlot(p.id, msg.Slot, p.pos.X, p.pos.Z)
	switch {
	case errors.Is(err, ErrNoSuchSlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoSuchSlot,
			Detail:      fmt.Sprintf("no such slot: %d is outside 0 to %d", msg.Slot, InventorySize-1),
			Re:          mnet.MsgDrop,
			Disposition: mnet.ReplyError,
		})
		return
	case errors.Is(err, ErrEmptySlot):
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonEmptySlot,
			Detail:      "that slot is empty",
			Re:          mnet.MsgDrop,
			Disposition: mnet.ReplyError,
		})
		return
	case err != nil:
		panic(fmt.Sprintf("game: dropping slot %d for player %d: %v", msg.Slot, p.id, err))
	}

	w.noteItemEntered(item)
	fields := playerItemFields(p.id, item.ID)
	fields["kind"] = item.Kind
	fields["slot"] = msg.Slot
	w.log.Event(w.tick, EvDrop, withSeq(fields, seq))

	w.broadcast(mnet.ItemSpawn{ID: item.ID, Kind: item.Kind, X: item.X, Z: item.Z}, nil)
	w.sendInventory(p)
}

func (w *World) resolvePickup(p *player) {
	item, live := w.items.GroundItem(p.pending)
	if !live {
		w.losePickup(p)
		return
	}
	if distanceBetween(p.pos, Point{X: item.X, Z: item.Z}) > PickupRange {
		return
	}

	slot, err := w.items.TakeGroundItem(item.ID, p.id)
	switch {
	case errors.Is(err, ErrInventoryFull):
		w.log.Event(w.tick, EvPickupNoRoom, playerItemFields(p.id, item.ID))
		p.pending = 0
		w.send(p, mnet.Error{Re: mnet.MsgPickup, Msg: "inventory is full"})
		return
	case errors.Is(err, ErrNoSuchItem):
		w.losePickup(p)
		return
	case err != nil:
		panic(fmt.Sprintf("game: taking item %d for player %d: %v", item.ID, p.id, err))
	}

	p.pending = 0
	fields := playerItemFields(p.id, item.ID)
	fields["kind"] = item.Kind
	fields["slot"] = slot.Index
	w.log.Event(w.tick, EvPickupResolved, fields)

	w.broadcast(mnet.ItemDespawn{ID: item.ID}, nil)
	w.sendInventory(p)
}

func (w *World) losePickup(p *player) {
	w.log.Event(w.tick, EvPickupLost, playerItemFields(p.id, p.pending))
	p.pending = 0
	w.assignHalt(p)
	w.send(p, mnet.Error{Re: mnet.MsgPickup, Msg: "the item is gone"})
}

func (w *World) assignHalt(p *player) {
	w.assignPath(p, []Point{p.pos})
}

func (w *World) sendInventory(p *player) {
	occupied := w.items.Inventory(p.id)
	slots := make([]mnet.InventorySlot, 0, len(occupied))
	for _, s := range occupied {
		slots = append(slots, mnet.InventorySlot{Slot: s.Index, Kind: s.Kind})
	}
	w.send(p, mnet.Inventory{Size: InventorySize, Slots: slots})
}

func (w *World) groundItemStates() []mnet.ItemState {
	items := w.items.GroundItems()
	states := make([]mnet.ItemState, 0, len(items))
	for _, item := range items {
		states = append(states, mnet.ItemState{ID: item.ID, Kind: item.Kind, X: item.X, Z: item.Z})
	}
	return states
}

func itemLogFields(item GroundItem) gamelog.Fields {
	return gamelog.Fields{
		"item": item.ID,
		"kind": item.Kind,
		"x":    item.X,
		"z":    item.Z,
	}
}

func playerItemFields(id mnet.PlayerID, item mnet.ItemID) gamelog.Fields {
	return gamelog.Fields{
		"player": id,
		"item":   item,
	}
}

func distanceBetween(a, b Point) float64 {
	return math.Hypot(b.X-a.X, b.Z-a.Z)
}
