package game

import (
	"errors"
	"fmt"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	GatherRange         = 0.5
	GatherDurationTicks = 3
	NodeRespawnTicks    = 20

	SeedTreeX = 5.0
	SeedTreeZ = 0.0

	KindTree = "tree"
	KindLogs = "logs"
)

type resourceNode struct {
	id        mnet.NodeID
	kind      string
	x, z      float64
	depleted  bool
	respawnAt int64
}

func (n *resourceNode) wireState() string {
	if n.depleted {
		return mnet.NodeDepleted
	}
	return mnet.NodeFull
}

func (n *resourceNode) wire() mnet.NodeState {
	return mnet.NodeState{
		ID:    n.id,
		Kind:  n.kind,
		X:     n.x,
		Z:     n.z,
		State: n.wireState(),
	}
}

func (w *World) SeedResourceNode(kind string, x, z float64) error {
	if kind == "" {
		return errors.New("seed node: kind must not be empty")
	}
	if reason, detail := checkCoordinates(x, z); reason != "" {
		return fmt.Errorf("seed node %q at (%v, %v): %s", kind, x, z, detail)
	}
	w.nextNodeID++
	n := &resourceNode{
		id:   w.nextNodeID,
		kind: kind,
		x:    x,
		z:    z,
	}
	w.nodes[n.id] = n
	w.nodeOrder = append(w.nodeOrder, n.id)
	w.log.Event(w.tick, EvNodeSpawned, nodeLogFields(n))
	return nil
}

func (w *World) nodeStates() []mnet.NodeState {
	states := make([]mnet.NodeState, 0, len(w.nodeOrder))
	for _, id := range w.nodeOrder {
		n, ok := w.nodes[id]
		if !ok {
			continue
		}
		states = append(states, n.wire())
	}
	return states
}

func (w *World) gather(p *player, msg mnet.Gather, seq mnet.Seq) {
	n, live := w.nodes[msg.Node]
	if !live {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownNode,
			Detail:      "no such node",
			Re:          mnet.MsgGather,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if n.depleted {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNodeDepleted,
			Detail:      "that node is depleted",
			Re:          mnet.MsgGather,
			Disposition: mnet.ReplyError,
		})
		return
	}
	if !w.wearingAxe(p) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonNeedsAxe,
			Detail:      "gather requires a worn axe",
			Re:          mnet.MsgGather,
			Disposition: mnet.ReplyError,
		})
		return
	}

	w.cancelGather(p)
	p.pending = 0
	p.gatherNode = n.id
	p.gatherProgress = 0
	w.log.Event(w.tick, EvGather, withSeq(playerNodeFields(p.id, n.id), seq))

	points, assign := destinationPath(p, Point{X: n.x, Z: n.z})
	if !assign {
		return
	}
	w.assignPath(p, points)
}

func (w *World) wearingAxe(p *player) bool {
	for _, worn := range w.items.Worn(p.id) {
		if worn.Slot == SlotWeapon && worn.Kind == KindAxe {
			return true
		}
	}
	return false
}

func (w *World) resolveGather(p *player) {
	n, live := w.nodes[p.gatherNode]
	if !live {
		w.loseGather(p)
		return
	}
	if n.depleted {
		w.loseGather(p)
		return
	}
	if distanceBetween(p.pos, Point{X: n.x, Z: n.z}) > GatherRange {
		w.cancelGather(p)
		return
	}
	if !w.wearingAxe(p) {
		w.cancelGather(p)
		return
	}

	p.gatherProgress++
	if p.gatherProgress < GatherDurationTicks {
		return
	}

	slot, err := w.items.SpawnInventoryItem(p.id, KindLogs)
	switch {
	case errors.Is(err, ErrInventoryFull):
		w.log.Event(w.tick, EvGatherNoRoom, playerNodeFields(p.id, n.id))
		w.clearGather(p)
		w.send(p, mnet.Error{Re: mnet.MsgGather, Msg: "inventory is full"})
		return
	case err != nil:
		panic(fmt.Sprintf("game: granting logs to player %d: %v", p.id, err))
	}

	w.clearGather(p)
	fields := playerNodeFields(p.id, n.id)
	fields["kind"] = KindLogs
	fields["slot"] = slot.Index
	w.log.Event(w.tick, EvGatherResolved, fields)

	w.depleteNode(n, p)
	w.sendInventory(p)
}

func (w *World) depleteNode(n *resourceNode, winner *player) {
	n.depleted = true
	n.respawnAt = w.tick + NodeRespawnTicks
	w.log.Event(w.tick, EvNodeDepleted, gamelog.Fields{"node": n.id})
	w.broadcast(mnet.NodeUpdate(n.wire()), nil)

	for _, p := range w.order {
		if p == winner || p.gatherNode != n.id {
			continue
		}
		w.loseGather(p)
	}
}

func (w *World) respawnNodes() {
	for _, id := range w.nodeOrder {
		n := w.nodes[id]
		if !n.depleted || w.tick < n.respawnAt {
			continue
		}
		n.depleted = false
		n.respawnAt = 0
		w.log.Event(w.tick, EvNodeRespawned, gamelog.Fields{"node": n.id})
		w.broadcast(mnet.NodeUpdate(n.wire()), nil)
	}
}

func (w *World) loseGather(p *player) {
	w.log.Event(w.tick, EvGatherLost, playerNodeFields(p.id, p.gatherNode))
	w.clearGather(p)
	w.assignHalt(p)
	w.send(p, mnet.Error{Re: mnet.MsgGather, Msg: "the node is gone"})
}

func (w *World) cancelGather(p *player) {
	if p.gatherNode == 0 {
		return
	}
	w.log.Event(w.tick, EvGatherCancelled, playerNodeFields(p.id, p.gatherNode))
	w.clearGather(p)
}

func (w *World) clearGather(p *player) {
	p.gatherNode = 0
	p.gatherProgress = 0
}

func nodeLogFields(n *resourceNode) gamelog.Fields {
	return gamelog.Fields{
		"node":  n.id,
		"kind":  n.kind,
		"x":     n.x,
		"z":     n.z,
		"state": n.wireState(),
	}
}

func playerNodeFields(id mnet.PlayerID, node mnet.NodeID) gamelog.Fields {
	return gamelog.Fields{
		"player": id,
		"node":   node,
	}
}
