package game

import (
	"errors"
	"fmt"

	mnet "github.com/devarminas/marque/server/internal/net"
)

// InventorySize is how many slots a player has. Twenty-eight, RuneScape's
// number, and the one server-side copy of it: the client is told the number in
// every inventory message rather than keeping a second one (PROTOCOL.md,
// "Inventory").
//
// One item per slot. Nothing stacks in M1, which keeps the slot the unit of
// every transaction.
const InventorySize = 28

// KindAcorn is the only item kind M1 ships. Kinds are opaque strings on the
// wire, so a second one is content rather than code.
const KindAcorn = "acorn"

// Errors a move can fail with. They are sentinels rather than strings because
// the caller answers each one differently on the wire: a vanished item makes a
// loser, and a full inventory does not.
var (
	// ErrNoSuchItem: the id names nothing lying on the ground. Covers a stale
	// id, an id belonging to an item somebody else already took, and an id that
	// never existed. Deliberately one error and not three: the server must not
	// tell a client which ids exist (PROTOCOL.md, "Pickup").
	ErrNoSuchItem = errors.New("game: no such ground item")
	// ErrInventoryFull: every slot is occupied.
	ErrInventoryFull = errors.New("game: inventory is full")
	// ErrNoSuchSlot: a slot index outside 0 to InventorySize-1. A broken
	// client rather than a stale one: no index in that range was ever legal.
	ErrNoSuchSlot = errors.New("game: no such inventory slot")
	// ErrEmptySlot: a legal slot index holding nothing. Separate from
	// ErrNoSuchSlot because the caller reports them separately, and because
	// they are different diagnoses: a client that drew the wrong grid, against
	// a client whose cached inventory is one transaction behind.
	ErrEmptySlot = errors.New("game: inventory slot is empty")
	// ErrNoSuchPlayer: the player has no inventory, meaning nobody ever called
	// AddPlayer for them or RemovePlayer already ran. Reaching it is a broken
	// invariant in the caller, not a condition to recover from.
	ErrNoSuchPlayer = errors.New("game: no such player")
)

// GroundItem is one item lying in the world.
type GroundItem struct {
	ID   mnet.ItemID
	Kind string
	X    float64
	Z    float64
}

// Slot is one occupied inventory slot.
type Slot struct {
	Index int
	Kind  string
}

// Store holds every item location in the game: what is on the ground, and what
// is in whose inventory. Nothing else may hold one, so "where is item 7" has
// exactly one answer and exactly one place to look for it.
//
// The interface is deliberately move-shaped. There is no Get paired with a Put,
// because a caller that reads a location and then writes a new one has made a
// two-phase write, and a transactional implementation cannot make those two
// phases atomic without changing every one of its callers. Standing order 6
// says Postgres arrives with zero game-logic change, so every state transition
// that must not half-happen is one method: TakeGroundItem moves an item from
// the ground into a slot, or does neither.
//
// The read methods (GroundItem, GroundItems, Inventory) exist to answer
// questions, never to stage a write. GroundItem tells the world where to walk;
// the walk does not license the take, and TakeGroundItem re-decides it.
//
// Ids are the store's to assign, because the store is what admits an item to
// the world. A Postgres implementation hands that to a sequence and the game
// logic above never learns the difference.
type Store interface {
	// AddPlayer gives a player an empty inventory. Calling it twice for one
	// player is a programming error.
	AddPlayer(mnet.PlayerID)

	// RemovePlayer forgets a player's inventory, and with it whatever was in
	// it. M1 has no persistence and no drop-on-logout: a leaver's items leave
	// with them. Calling it for an unknown player is a no-op, because a
	// connection can die in more ways than it can be born.
	RemovePlayer(mnet.PlayerID)

	// SpawnGroundItem places a new item of kind at (x, z) and names it. The
	// returned GroundItem carries the id the store assigned.
	SpawnGroundItem(kind string, x, z float64) GroundItem

	// GroundItems lists every item on the ground, oldest first. The order is
	// part of the contract: welcome's item list must be identical across two
	// identical runs, and Go randomises map iteration.
	GroundItems() []GroundItem

	// GroundItem looks up one item by id, reporting false when no item of that
	// id is on the ground.
	GroundItem(mnet.ItemID) (GroundItem, bool)

	// TakeGroundItem moves one item from the ground into one player's
	// inventory, and is the only way an item crosses between the two. It
	// either happens completely or leaves both sides untouched.
	//
	// The slot is chosen by the store, lowest free index first, which is
	// RuneScape's rule. The caller cannot choose it: naming a slot would mean
	// reading the inventory first, and that read plus this write is the
	// two-phase shape this interface exists to forbid.
	//
	// Fails with ErrNoSuchItem, ErrInventoryFull, or ErrNoSuchPlayer.
	TakeGroundItem(mnet.ItemID, mnet.PlayerID) (Slot, error)

	// DropInventorySlot moves whatever is in one of a player's slots out onto
	// the ground at (x, z), and is the only way an item crosses back. Like
	// TakeGroundItem it either happens completely or leaves both sides
	// untouched: one call, never a read of the slot followed by a write of the
	// ground.
	//
	// The returned GroundItem carries a **new** id, freshly assigned from the
	// store's counter. That is forced rather than chosen: an inventory holds
	// kinds, not item ids, so the id an item had before it was picked up is
	// already unrecoverable by the time it is dropped, and ids are never reused
	// within a process (PROTOCOL.md, "Entity naming"). A client that cached the
	// old id sees a body it has never heard of, which is exactly right, because
	// it was told that one despawned.
	//
	// The coordinate is not validated here. It is the dropping player's own
	// position, which is already in world state and therefore already inside
	// the bounds checkCoordinates enforces; every position is either the spawn
	// point or a convex combination of validated waypoints. A caller passing
	// anything else is the bug, and a check here would answer it too late to
	// help.
	//
	// Fails with ErrNoSuchPlayer, ErrNoSuchSlot, or ErrEmptySlot.
	DropInventorySlot(player mnet.PlayerID, slot int, x, z float64) (GroundItem, error)

	// Inventory lists one player's occupied slots, ascending by index. Absent
	// slots are empty. An unknown player has no inventory and returns nil.
	Inventory(mnet.PlayerID) []Slot
}

// memStore is the in-memory Store.
//
// Not safe for concurrent use, and deliberately not made so. Every method is
// called from the one goroutine running World.Run, which owns all game state
// (CLAUDE.md, "Architecture invariants"). A mutex here would buy nothing and
// would advertise a thread-safety that the surrounding code does not have and
// must not start relying on. The only exception is World's seeding step, which
// runs before Run starts and therefore before any second goroutine exists.
type memStore struct {
	nextItemID mnet.ItemID

	// ground is the authoritative set of items lying in the world; order is the
	// ids in the sequence they entered it, which is what GroundItems iterates.
	// The two are updated together and never separately.
	ground map[mnet.ItemID]GroundItem
	order  []mnet.ItemID

	// inventories is one fixed-size slot array per player. An empty slot holds
	// the empty string, which no legal kind is.
	inventories map[mnet.PlayerID]*[InventorySize]string
}

// NewMemoryStore returns an empty in-memory Store. Item ids start at 1.
func NewMemoryStore() Store {
	return &memStore{
		ground:      make(map[mnet.ItemID]GroundItem),
		inventories: make(map[mnet.PlayerID]*[InventorySize]string),
	}
}

func (s *memStore) AddPlayer(id mnet.PlayerID) {
	if _, dup := s.inventories[id]; dup {
		panic(fmt.Sprintf("game: player %d already has an inventory", id))
	}
	s.inventories[id] = &[InventorySize]string{}
}

func (s *memStore) RemovePlayer(id mnet.PlayerID) {
	delete(s.inventories, id)
}

func (s *memStore) SpawnGroundItem(kind string, x, z float64) GroundItem {
	if kind == "" {
		panic("game: ground item with no kind")
	}
	s.nextItemID++
	item := GroundItem{ID: s.nextItemID, Kind: kind, X: x, Z: z}
	s.ground[item.ID] = item
	s.order = append(s.order, item.ID)
	return item
}

func (s *memStore) GroundItems() []GroundItem {
	items := make([]GroundItem, 0, len(s.ground))
	for _, id := range s.order {
		item, ok := s.ground[id]
		if !ok {
			// Taken. order is append-only and keeps the ids of items that have
			// left, so that an item which came back could not jump the queue;
			// ids are never reused, so it never can.
			continue
		}
		items = append(items, item)
	}
	return items
}

func (s *memStore) GroundItem(id mnet.ItemID) (GroundItem, bool) {
	item, ok := s.ground[id]
	return item, ok
}

func (s *memStore) TakeGroundItem(id mnet.ItemID, player mnet.PlayerID) (Slot, error) {
	item, onGround := s.ground[id]
	if !onGround {
		return Slot{}, fmt.Errorf("take item %d for player %d: %w", id, player, ErrNoSuchItem)
	}
	slots, known := s.inventories[player]
	if !known {
		return Slot{}, fmt.Errorf("take item %d for player %d: %w", id, player, ErrNoSuchPlayer)
	}

	index := -1
	for i, kind := range slots {
		if kind == "" {
			index = i
			break
		}
	}
	if index < 0 {
		return Slot{}, fmt.Errorf("take item %d for player %d: %w", id, player, ErrInventoryFull)
	}

	// Both sides of the move, with nothing between them that can fail. Every
	// reason to refuse has already been checked, so this is the transaction:
	// the item is off the ground and in the slot, or neither.
	delete(s.ground, id)
	slots[index] = item.Kind

	return Slot{Index: index, Kind: item.Kind}, nil
}

func (s *memStore) DropInventorySlot(player mnet.PlayerID, slot int, x, z float64) (GroundItem, error) {
	slots, known := s.inventories[player]
	if !known {
		return GroundItem{}, fmt.Errorf("drop slot %d for player %d: %w", slot, player, ErrNoSuchPlayer)
	}
	if slot < 0 || slot >= InventorySize {
		return GroundItem{}, fmt.Errorf("drop slot %d for player %d: %w", slot, player, ErrNoSuchSlot)
	}
	kind := slots[slot]
	if kind == "" {
		return GroundItem{}, fmt.Errorf("drop slot %d for player %d: %w", slot, player, ErrEmptySlot)
	}

	// Both sides of the move, with nothing between them that can fail. Every
	// reason to refuse has already been checked, so this is the transaction:
	// the slot is empty and the item is on the ground, or neither. The spawn
	// cannot fail either -- kind is non-empty, which is the only thing
	// SpawnGroundItem refuses.
	slots[slot] = ""
	item := s.SpawnGroundItem(kind, x, z)

	return item, nil
}

func (s *memStore) Inventory(player mnet.PlayerID) []Slot {
	slots, known := s.inventories[player]
	if !known {
		return nil
	}
	var occupied []Slot
	for i, kind := range slots {
		if kind == "" {
			continue
		}
		occupied = append(occupied, Slot{Index: i, Kind: kind})
	}
	return occupied
}
