package game

// Ground items, inventories, and the pickup transaction.
//
// Everything here runs on the goroutine that owns world state, with one stated
// exception: SeedGroundItem, which runs before that goroutine starts.
//
// PROTOCOL.md, "Items and inventory", is the contract.

import (
	"errors"
	"fmt"
	"math"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// PickupRange is how near a player must be to a ground item to take it, in
// world units.
//
// It governs resolution only, and never path assignment. It is the distance at
// which the tick loop hands you the item. It is not, and must never become, a
// distance at which the server declines to walk you: that carve-out was in the
// contract once, it broke a pickup by a player who was already walking, and
// deleting it rather than patching under it is what PROTOCOL.md, "Pickup", now
// says.
//
// Being larger than one tick of walking (WalkSpeed * TickDuration = 0.45 units)
// is now a consequence rather than an invariant, and it used to be neither. A
// player usually enters the range with a waypoint still ahead of them, which the
// resolution code handles: reaching the range is what licenses the take, and
// arriving is what ends the walk. Nothing breaks if a smaller value makes
// arrival the usual moment instead, because the path a pending pickup walks ends
// at the item.
//
// It must stay at or above MinPathLength, which is the one coupling it has left.
// A pickup of the item underfoot assigns no path, so the sub-millimetre gap it
// leaves is never closed by walking and resolution has to accept it.
// TestPickupOfTheItemUnderfootAssignsNoPath holds that.
//
// Placeholder, chosen to be small enough to read as "standing on it" and large
// enough to swallow the arithmetic of arrival. Revisitable, and parked in
// FOLLOW-UPS.md along with every other number that is about feel.
const PickupRange = 0.5

// SeedGroundItem puts one item into the world before it opens.
//
// It must be called before Run, and it is the only method on World that may be
// called from another goroutine, because before Run there is no other goroutine
// to race with. Calling it afterwards races the tick loop against the store.
//
// The coordinate is validated exactly as a move_to destination is: an item
// outside the world would be a body the client cannot render and a destination
// no player can legally walk to, so it is a startup failure rather than a
// silently clamped position.
func (w *World) SeedGroundItem(kind string, x, z float64) error {
	if kind == "" {
		return errors.New("seed item: kind must not be empty")
	}
	if reason, detail := checkCoordinates(x, z); reason != "" {
		return fmt.Errorf("seed item %q at (%v, %v): %s", kind, x, z, detail)
	}
	w.admitGroundItem(kind, x, z)
	return nil
}

// admitGroundItem places an item and logs it. Every way an item enters the
// world goes through here, so the log records all of them the same way and
// M1b's drop has one line to add rather than a shape to copy.
//
// It does not broadcast. Seeding happens before anyone is connected, and a
// caller with an audience broadcasts the returned item itself.
func (w *World) admitGroundItem(kind string, x, z float64) GroundItem {
	item := w.items.SpawnGroundItem(kind, x, z)
	w.log.Event(w.tick, EvItemSpawned, itemLogFields(item))
	return item
}

// pickup answers a click on an item.
//
// It assigns a path exactly as move_to does and records what the walk is for.
// Nothing is taken here: taking happens in step, on the tick the player is near
// enough, which is what makes a contested pickup a contest rather than a race
// between two network arrivals.
func (w *World) pickup(p *player, msg mnet.Pickup) {
	w.log.Event(w.tick, EvPickup, pickupLogFields(p.id, msg.Item))

	item, live := w.items.GroundItem(msg.Item)
	if !live {
		// One answer for a stale id, an id somebody else already took, and an
		// id that never existed. The server must not tell a client which ids
		// exist (PROTOCOL.md, "Pickup").
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnknownItem,
			Detail:      "no such item",
			Re:          mnet.MsgPickup,
			Disposition: mnet.ReplyError,
		})
		return
	}

	// A second pickup replaces the first, and this is where. The player keeps
	// whatever walk the previous intent gave them only until the lines below
	// overwrite it.
	p.pending = item.ID

	// A move_to at the item's position, and nothing else. No distance carve-out:
	// how near the player already is decides when the item is handed over, never
	// whether a path is assigned.
	points, assign := destinationPath(p, Point{X: item.X, Z: item.Z})
	if !assign {
		// Standing on the item. This is the one place a pickup differs from a
		// move_to, which would answer "already there": there is something left
		// to do, so no path is assigned, nothing is broadcast, and the pending
		// pickup resolves on the next tick through the same resolution every
		// other pickup uses.
		return
	}
	w.assignPath(p, points)
}

// resolvePickup decides one player's pending pickup for this tick. Called from
// step, after movement, in join order.
//
// Three outcomes end the pending state and one does not: still too far away is
// not an outcome, it is the ordinary case on every tick of the walk.
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
		// The item stays on the ground and the player simply stops there. No
		// halt path: the walk ends by arriving, which it is about to do on its
		// own, and cutting it short here would freeze the server's copy of the
		// player up to PickupRange short of where the client draws them.
		w.log.Event(w.tick, EvPickupNoRoom, pickupLogFields(p.id, item.ID))
		p.pending = 0
		w.send(p, mnet.Error{Re: mnet.MsgPickup, Msg: "inventory is full"})
		return
	case errors.Is(err, ErrNoSuchItem):
		// Lost between the lookup two lines above and the take. Unreachable on
		// one goroutine, and handled rather than asserted because the whole
		// point of the move-shaped interface is that a transactional store may
		// legitimately answer this.
		w.losePickup(p)
		return
	case err != nil:
		// ErrNoSuchPlayer, or something a later Store invents. A player in
		// w.order without an inventory is a broken invariant in addPlayer, not
		// a condition to recover from.
		panic(fmt.Sprintf("game: taking item %d for player %d: %v", item.ID, p.id, err))
	}

	p.pending = 0
	fields := pickupLogFields(p.id, item.ID)
	fields["kind"] = item.Kind
	fields["slot"] = slot.Index
	w.log.Event(w.tick, EvPickupResolved, fields)

	// One tick, one goroutine, one transaction: the item is off the ground, in
	// a slot, and everyone has been told, before any other player in this pass
	// is looked at.
	w.broadcast(mnet.ItemDespawn{ID: item.ID}, nil)
	w.sendInventory(p)
}

// losePickup is what happens to everybody who was walking to an item that
// somebody else took.
//
// A one-element halt path at the loser's current position, broadcast like any
// other path, plus an error naming pickup. Walking on to an empty patch of
// ground would be the server lying about the world.
//
// The halt is sent even when the loser was standing still, which happens when
// they were standing on the item and lost the same tick they asked. The protocol
// states the rule without a condition, and a client that holds at the last point
// of its polyline is unmoved by being told to stand where it stands.
func (w *World) losePickup(p *player) {
	w.log.Event(w.tick, EvPickupLost, pickupLogFields(p.id, p.pending))
	p.pending = 0
	w.assignHalt(p)
	w.send(p, mnet.Error{Re: mnet.MsgPickup, Msg: "the item is gone"})
}

// assignHalt stops a player where they stand and tells everyone.
//
// It stops them on both sides at once: the one-element polyline empties the
// server's waypoints and is a complete instruction to the client, which holds at
// the final point of whatever path it was last given. It broadcasts because
// every observer is drawing that walk too.
func (w *World) assignHalt(p *player) {
	w.assignPath(p, []Point{p.pos})
}

// sendInventory restates one player's whole inventory to that player.
//
// Sent when their inventory changes and once inside the welcome step, and never
// otherwise: it is private to one player and there is nothing in it another
// client could use.
func (w *World) sendInventory(p *player) {
	occupied := w.items.Inventory(p.id)
	slots := make([]mnet.InventorySlot, 0, len(occupied))
	for _, s := range occupied {
		slots = append(slots, mnet.InventorySlot{Slot: s.Index, Kind: s.Kind})
	}
	// slots is deliberately non-nil even when empty, so an empty inventory
	// encodes as "slots":[] rather than as null.
	w.send(p, mnet.Inventory{Size: InventorySize, Slots: slots})
}

// groundItemStates is the world's items as welcome describes them.
func (w *World) groundItemStates() []mnet.ItemState {
	items := w.items.GroundItems()
	states := make([]mnet.ItemState, 0, len(items))
	for _, item := range items {
		states = append(states, mnet.ItemState{ID: item.ID, Kind: item.Kind, X: item.X, Z: item.Z})
	}
	return states
}

// itemLogFields describes one ground item for the event log.
func itemLogFields(item GroundItem) gamelog.Fields {
	return gamelog.Fields{
		"item": item.ID,
		"kind": item.Kind,
		"x":    item.X,
		"z":    item.Z,
	}
}

// pickupLogFields names the player and the item for every event about a pickup,
// so the four of them cannot drift apart on a key name. EvPickupResolved adds
// "kind" and "slot" on top, being the only one that knows either.
func pickupLogFields(id mnet.PlayerID, item mnet.ItemID) gamelog.Fields {
	return gamelog.Fields{
		"player": id,
		"item":   item,
	}
}

func distanceBetween(a, b Point) float64 {
	return math.Hypot(b.X-a.X, b.Z-a.Z)
}
