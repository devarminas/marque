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

func (p *player) hasPendingUse() bool {
	return p.pendingUseOn != 0
}

func (w *World) clearPendingUse(p *player) {
	p.pendingUseSlot = 0
	p.pendingUseOn = 0
	p.pendingUseSeq = 0
}

func (w *World) armPendingUse(p *player) {
	w.clearPendingUse(p)
	p.pending = 0
	w.clearPendingTalk(p)
	w.cancelGather(p)
	w.cancelAttack(p, CauseUse)
	w.cancelCast(p, CauseUse)
	p.clearSteer()
}

func (w *World) useOnStation(p *player, msg mnet.Use, seq mnet.Seq) {
	station, consumeKind, produceKind, rejection := w.stationUsePrep(p, msg)
	if rejection != nil {
		w.refuse(p, rejection)
		return
	}

	w.armPendingUse(p)
	dest := Point{X: station.x, Z: station.z}
	if distanceBetween(p.pos, dest) > StationRange {
		p.pendingUseSlot = msg.Slot
		p.pendingUseOn = msg.On
		p.pendingUseSeq = seq
		w.steerToward(p, dest)
		return
	}

	w.completeStationUse(p, msg, station, consumeKind, produceKind, seq)
}

func (w *World) resolveUse(p *player) {
	if !p.hasPendingUse() {
		return
	}
	msg := mnet.Use{Slot: p.pendingUseSlot, On: p.pendingUseOn}
	station, consumeKind, produceKind, rejection := w.stationUsePrep(p, msg)
	if rejection != nil {
		w.clearPendingUse(p)
		p.clearSteer()
		w.refuse(p, rejection)
		return
	}
	if distanceBetween(p.pos, Point{X: station.x, Z: station.z}) > StationRange {
		return
	}
	seq := p.pendingUseSeq
	w.clearPendingUse(p)
	if p.steering() {
		p.clearSteer()
	}
	w.completeStationUse(p, msg, station, consumeKind, produceKind, seq)
}

func (w *World) stationUsePrep(
	p *player, msg mnet.Use,
) (*resourceNode, string, string, *mnet.RejectError) {
	station, live := w.nodes[mnet.NodeID(msg.On)]
	if !live || !isStation(station.kind) {
		return nil, "", "", &mnet.RejectError{
			Reason:      mnet.ReasonNoRecipe,
			Detail:      "that cannot be crafted",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		}
	}

	if msg.Slot < 0 || msg.Slot >= InventorySize {
		return nil, "", "", &mnet.RejectError{
			Reason:      mnet.ReasonNoSuchSlot,
			Detail:      fmt.Sprintf("no such slot: %d is outside 0 to %d", msg.Slot, InventorySize-1),
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		}
	}

	consumeKind := ""
	for _, slot := range w.items.Inventory(p.id) {
		if slot.Index == msg.Slot {
			consumeKind = slot.Kind
			break
		}
	}
	if consumeKind == "" {
		return nil, "", "", &mnet.RejectError{
			Reason:      mnet.ReasonEmptySlot,
			Detail:      "that slot is empty",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		}
	}

	produceKind, ok := stationRecipe(station.kind, consumeKind)
	if !ok {
		return nil, "", "", &mnet.RejectError{
			Reason:      mnet.ReasonNoRecipe,
			Detail:      "that cannot be crafted",
			Re:          mnet.MsgUse,
			Disposition: mnet.ReplyError,
		}
	}
	return station, consumeKind, produceKind, nil
}

func (w *World) completeStationUse(
	p *player,
	msg mnet.Use,
	station *resourceNode,
	consumeKind, produceKind string,
	seq mnet.Seq,
) {
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
