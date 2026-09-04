package game

import (
	"errors"
	"fmt"

	mnet "github.com/devarminas/marque/server/internal/net"
)

// InventorySize is how many slots a player has; the client is told it in every
// inventory message (PROTOCOL.md, "Inventory").
const InventorySize = 28

// KindAcorn is the only item kind shipped. Kinds are opaque strings on the wire.
const KindAcorn = "acorn"

var (
	// ErrNoSuchItem: the id names nothing on the ground, whether stale, taken,
	// or invented (PROTOCOL.md, "Pickup").
	ErrNoSuchItem = errors.New("game: no such ground item")
	// ErrInventoryFull: every slot is occupied.
	ErrInventoryFull = errors.New("game: inventory is full")
	// ErrNoSuchSlot: a slot index outside 0 to InventorySize-1.
	ErrNoSuchSlot = errors.New("game: no such inventory slot")
	// ErrEmptySlot: a legal slot index holding nothing.
	ErrEmptySlot = errors.New("game: inventory slot is empty")
	// ErrNoSuchPlayer: the player has no inventory.
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

// Store holds every item location in the game: what is on the ground and what
// is in whose inventory. The interface is move-shaped, with no Get/Put pair,
// so every transition that must not half-happen is one method.
type Store interface {
	// AddPlayer gives a player an empty inventory. Calling it twice for one
	// player is a programming error.
	AddPlayer(mnet.PlayerID)

	// RemovePlayer forgets a player's inventory and whatever was in it. An
	// unknown player is a no-op.
	RemovePlayer(mnet.PlayerID)

	// SpawnGroundItem places a new item of kind at (x, z) and returns it with
	// the id the store assigned.
	SpawnGroundItem(kind string, x, z float64) GroundItem

	// GroundItems lists every item on the ground, oldest first.
	GroundItems() []GroundItem

	// GroundItem looks up one item by id, reporting false when no item of that
	// id is on the ground.
	GroundItem(mnet.ItemID) (GroundItem, bool)

	// TakeGroundItem moves one item from the ground into the lowest free slot
	// of one player's inventory, completely or not at all. Fails with
	// ErrNoSuchItem, ErrInventoryFull, or ErrNoSuchPlayer.
	TakeGroundItem(mnet.ItemID, mnet.PlayerID) (Slot, error)

	// DropInventorySlot moves whatever is in one of a player's slots onto the
	// ground at (x, z), completely or not at all; the returned GroundItem has a
	// new id. Fails with ErrNoSuchPlayer, ErrNoSuchSlot, or ErrEmptySlot.
	DropInventorySlot(player mnet.PlayerID, slot int, x, z float64) (GroundItem, error)

	// Inventory lists one player's occupied slots, ascending by index. An
	// unknown player returns nil.
	Inventory(mnet.PlayerID) []Slot
}

type memStore struct {
	nextItemID mnet.ItemID

	ground map[mnet.ItemID]GroundItem
	order  []mnet.ItemID

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
