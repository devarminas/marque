package game

import (
	"fmt"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	KindSmelter   = "smelter"
	KindCopperBar = "copper_bar"

	StationRange = PickupRange

	SeedSmelterX = 0.0
	SeedSmelterZ = 3.0
)

// StarterTownSmelters are craft stations near the hub on the Northmere road.
var StarterTownSmelters = []Point{
	{X: SeedSmelterX, Z: SeedSmelterZ},
}

func isStation(kind string) bool {
	return kind == KindSmelter
}

func stationRecipe(stationKind, consumeKind string) (string, bool) {
	if stationKind == KindSmelter && consumeKind == KindCopperOre {
		return KindCopperBar, true
	}
	return "", false
}

func (w *World) useOnStation(p *player, msg mnet.Use, seq mnet.Seq) {
	station, live := w.nodes[mnet.NodeID(msg.On)]
	if !live || !isStation(station.kind) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoRecipe,
			Detail:      "that cannot be crafted",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if distanceBetween(p.pos, Point{X: station.x, Z: station.z}) > StationRange {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonOutOfRange,
			Detail:      "too far from that station",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
		return
	}

	if msg.Slot < 0 || msg.Slot >= InventorySize {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoSuchSlot,
			Detail:      fmt.Sprintf("no such slot: %d is outside 0 to %d", msg.Slot, InventorySize-1),
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
		return
	}

	consumeKind := ""
	for _, slot := range w.items.Inventory(p.id) {
		if slot.Index == msg.Slot {
			consumeKind = slot.Kind
			break
		}
	}
	if consumeKind == "" {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonEmptySlot,
			Detail:      "that slot is empty",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
		return
	}

	produceKind, ok := stationRecipe(station.kind, consumeKind)
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNoRecipe,
			Detail:      "that cannot be crafted",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		})
		return
	}

	done, err := w.items.CraftInventorySlot(p.id, msg.Slot, consumeKind, produceKind)
	if err != nil {
		w.refuseCraft(p, msg.Slot, err)
		return
	}

	w.log.Event(w.tick, EvUse, withSeq(gamelog.Fields{
		"player":  p.id,
		"slot":    msg.Slot,
		"on":      msg.On,
		"station": station.id,
		"from":    done.Consume,
		"to":      done.Produce,
	}, seq))

	w.sendInventory(p)
}
