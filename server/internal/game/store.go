package game

import (
	"errors"
	"fmt"

	mnet "github.com/devarminas/marque/server/internal/net"
)

// InventorySize is how many slots a player has; the client is told it in every
// inventory message (PROTOCOL.md, "Inventory").
const InventorySize = 28

// Item kinds. Kinds are opaque strings on the wire.
const (
	KindAcorn = "acorn"
	// KindAxe is M3a's equippable kind, and the only one. Tuning: ARM-81.
	KindAxe = "axe"
)

// SlotWeapon is the only worn slot M3a has (PROTOCOL.md, "Worn slots").
const SlotWeapon mnet.EquipSlot = "weapon"

// WornSlots is the closed, ordered list of worn slot names, in the order a
// client draws them. It rides on the wire in every equipment restatement so the
// client never holds a second copy of it. Read-only.
var WornSlots = []mnet.EquipSlot{SlotWeapon}

// wornSlotOf says which worn slot a kind belongs in. A kind absent from the
// table cannot be worn, which is how acorn is refused: a lookup that misses,
// not a rule naming the kinds that are not weapons. Adding a wearable kind is
// one line here plus its name in WornSlots.
var wornSlotOf = map[string]mnet.EquipSlot{
	KindAxe: SlotWeapon,
}

// DefaultJoinKit is what a joining player is given, in the order it is placed:
// one axe, so a client can reach equip before gathering exists to earn one.
// Revisitable the moment gathering can produce one. Tuning: ARM-81.
var DefaultJoinKit = []string{KindAxe}

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
	// ErrNotEquippable: the kind belongs to no worn slot (PROTOCOL.md, "equip").
	ErrNotEquippable = errors.New("game: that kind cannot be worn")
	// ErrNoSuchWornSlot: a worn slot name this server does not have.
	ErrNoSuchWornSlot = errors.New("game: no such worn slot")
	// ErrEmptyWornSlot: a worn slot this server has, holding nothing.
	ErrEmptyWornSlot = errors.New("game: worn slot is empty")
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

// WornSlot is one occupied worn equipment slot.
type WornSlot struct {
	Slot mnet.EquipSlot
	Kind string
}

// Equipped records one equip: Kind left bag slot Bag for worn slot Worn, and
// Displaced is whatever Worn held before and now sits in Bag. Displaced is
// empty when Worn was free, which is the only thing that distinguishes a swap
// from an ordinary equip.
type Equipped struct {
	Worn      mnet.EquipSlot
	Kind      string
	Bag       int
	Displaced string
}

// Unequipped records one unequip: Kind left worn slot Worn for bag slot Bag.
type Unequipped struct {
	Worn mnet.EquipSlot
	Kind string
	Bag  int
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

	// SpawnInventoryItem puts a new item of kind into the lowest free slot of
	// one player's inventory, without it ever being on the ground: no id is
	// minted, because an inventory holds kinds. Fails with ErrNoSuchPlayer or
	// ErrInventoryFull.
	SpawnInventoryItem(player mnet.PlayerID, kind string) (Slot, error)

	// EquipInventorySlot moves whatever is in one of a player's bag slots into
	// the worn slot its kind belongs in, completely or not at all. An occupied
	// worn slot swaps: what was worn lands in the bag slot just vacated. Fails
	// with ErrNoSuchPlayer, ErrNoSuchSlot, ErrEmptySlot, or ErrNotEquippable.
	EquipInventorySlot(player mnet.PlayerID, slot int) (Equipped, error)

	// UnequipWornSlot moves whatever is in one of a player's worn slots into the
	// lowest free slot of their inventory, completely or not at all. Fails with
	// ErrNoSuchPlayer, ErrNoSuchWornSlot, ErrEmptyWornSlot, or ErrInventoryFull.
	UnequipWornSlot(player mnet.PlayerID, slot mnet.EquipSlot) (Unequipped, error)

	// Inventory lists one player's occupied slots, ascending by index. An
	// unknown player returns nil.
	Inventory(mnet.PlayerID) []Slot

	// Worn lists one player's occupied worn slots, in WornSlots order. An
	// unknown player returns nil.
	Worn(mnet.PlayerID) []WornSlot
}

// playerItems is everything one player is carrying: the bag, and what is worn.
// Both live in one value so that a move between them is one assignment pair
// under one owner, which is what makes an equip impossible to half-do.
type playerItems struct {
	bag  [InventorySize]string
	worn map[mnet.EquipSlot]string
}

// free reports the lowest empty bag slot, RuneScape's fill order and the one
// every path into the bag uses.
func (p *playerItems) free() (int, bool) {
	for i, kind := range p.bag {
		if kind == "" {
			return i, true
		}
	}
	return 0, false
}

type memStore struct {
	nextItemID mnet.ItemID

	ground map[mnet.ItemID]GroundItem
	order  []mnet.ItemID

	held map[mnet.PlayerID]*playerItems
}

// NewMemoryStore returns an empty in-memory Store. Item ids start at 1.
func NewMemoryStore() Store {
	return &memStore{
		ground: make(map[mnet.ItemID]GroundItem),
		held:   make(map[mnet.PlayerID]*playerItems),
	}
}

func (s *memStore) AddPlayer(id mnet.PlayerID) {
	if _, dup := s.held[id]; dup {
		panic(fmt.Sprintf("game: player %d already has an inventory", id))
	}
	s.held[id] = &playerItems{worn: make(map[mnet.EquipSlot]string, len(WornSlots))}
}

func (s *memStore) RemovePlayer(id mnet.PlayerID) {
	delete(s.held, id)
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
	held, known := s.held[player]
	if !known {
		return Slot{}, fmt.Errorf("take item %d for player %d: %w", id, player, ErrNoSuchPlayer)
	}
	index, room := held.free()
	if !room {
		return Slot{}, fmt.Errorf("take item %d for player %d: %w", id, player, ErrInventoryFull)
	}

	delete(s.ground, id)
	held.bag[index] = item.Kind

	return Slot{Index: index, Kind: item.Kind}, nil
}

func (s *memStore) DropInventorySlot(player mnet.PlayerID, slot int, x, z float64) (GroundItem, error) {
	held, known := s.held[player]
	if !known {
		return GroundItem{}, fmt.Errorf("drop slot %d for player %d: %w", slot, player, ErrNoSuchPlayer)
	}
	if slot < 0 || slot >= InventorySize {
		return GroundItem{}, fmt.Errorf("drop slot %d for player %d: %w", slot, player, ErrNoSuchSlot)
	}
	kind := held.bag[slot]
	if kind == "" {
		return GroundItem{}, fmt.Errorf("drop slot %d for player %d: %w", slot, player, ErrEmptySlot)
	}

	held.bag[slot] = ""
	item := s.SpawnGroundItem(kind, x, z)

	return item, nil
}

func (s *memStore) SpawnInventoryItem(player mnet.PlayerID, kind string) (Slot, error) {
	if kind == "" {
		panic(fmt.Sprintf("game: inventory item with no kind for player %d", player))
	}
	held, known := s.held[player]
	if !known {
		return Slot{}, fmt.Errorf("give %q to player %d: %w", kind, player, ErrNoSuchPlayer)
	}
	index, room := held.free()
	if !room {
		return Slot{}, fmt.Errorf("give %q to player %d: %w", kind, player, ErrInventoryFull)
	}

	held.bag[index] = kind

	return Slot{Index: index, Kind: kind}, nil
}

func (s *memStore) EquipInventorySlot(player mnet.PlayerID, slot int) (Equipped, error) {
	held, known := s.held[player]
	if !known {
		return Equipped{}, fmt.Errorf("equip slot %d for player %d: %w", slot, player, ErrNoSuchPlayer)
	}
	if slot < 0 || slot >= InventorySize {
		return Equipped{}, fmt.Errorf("equip slot %d for player %d: %w", slot, player, ErrNoSuchSlot)
	}
	kind := held.bag[slot]
	if kind == "" {
		return Equipped{}, fmt.Errorf("equip slot %d for player %d: %w", slot, player, ErrEmptySlot)
	}
	worn, wearable := wornSlotOf[kind]
	if !wearable {
		return Equipped{}, fmt.Errorf("equip %q from slot %d for player %d: %w", kind, slot, player, ErrNotEquippable)
	}

	// The exchange, and the reason this is one method rather than a get and a
	// put. Whatever was worn takes the bag slot the new item is leaving, so a
	// swap needs no free slot and cannot fail for want of one.
	displaced := held.worn[worn]
	held.worn[worn] = kind
	held.bag[slot] = displaced

	return Equipped{Worn: worn, Kind: kind, Bag: slot, Displaced: displaced}, nil
}

func (s *memStore) UnequipWornSlot(player mnet.PlayerID, slot mnet.EquipSlot) (Unequipped, error) {
	held, known := s.held[player]
	if !known {
		return Unequipped{}, fmt.Errorf("unequip %q for player %d: %w", slot, player, ErrNoSuchPlayer)
	}
	if !wornSlotExists(slot) {
		return Unequipped{}, fmt.Errorf("unequip %q for player %d: %w", slot, player, ErrNoSuchWornSlot)
	}
	kind := held.worn[slot]
	if kind == "" {
		return Unequipped{}, fmt.Errorf("unequip %q for player %d: %w", slot, player, ErrEmptyWornSlot)
	}
	index, room := held.free()
	if !room {
		return Unequipped{}, fmt.Errorf("unequip %q for player %d: %w", slot, player, ErrInventoryFull)
	}

	delete(held.worn, slot)
	held.bag[index] = kind

	return Unequipped{Worn: slot, Kind: kind, Bag: index}, nil
}

func (s *memStore) Inventory(player mnet.PlayerID) []Slot {
	held, known := s.held[player]
	if !known {
		return nil
	}
	var occupied []Slot
	for i, kind := range held.bag {
		if kind == "" {
			continue
		}
		occupied = append(occupied, Slot{Index: i, Kind: kind})
	}
	return occupied
}

func (s *memStore) Worn(player mnet.PlayerID) []WornSlot {
	held, known := s.held[player]
	if !known {
		return nil
	}
	var occupied []WornSlot
	for _, slot := range WornSlots {
		if kind := held.worn[slot]; kind != "" {
			occupied = append(occupied, WornSlot{Slot: slot, Kind: kind})
		}
	}
	return occupied
}

func wornSlotExists(slot mnet.EquipSlot) bool {
	for _, known := range WornSlots {
		if known == slot {
			return true
		}
	}
	return false
}
