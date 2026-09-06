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
	// KindAxe is M3a's equippable kind, now one of nine wearable kinds. Tuning: ARM-81.
	KindAxe = "axe"
	// KindSword is the knight's one-handed tool. M7b.
	KindSword = "sword"
	// KindStaff is the mage's two-handed tool. M7b.
	KindStaff = "staff"
	// KindBow is the archer's two-handed tool. M7b.
	KindBow = "bow"
	// KindLumberjackAxe is the lumberjack's two-handed tool, a distinct kind
	// from the one-handed KindAxe. M7b.
	KindLumberjackAxe = "lumberjack axe"
	// KindPickaxe is the miner's one-handed tool. M7b.
	KindPickaxe = "pickaxe"
	// KindProspectorBoots is the prospector's footwear, and the reason the
	// feet slot exists. M7b.
	KindProspectorBoots = "prospector boots"
)

// Worn slot names on the wire (PROTOCOL.md, "Worn slots"). Exact strings,
// including spaces.
const (
	SlotHelmet    mnet.EquipSlot = "helmet"
	SlotLeftHand  mnet.EquipSlot = "left hand"
	SlotChest     mnet.EquipSlot = "chest"
	SlotRightHand mnet.EquipSlot = "right hand"
	SlotFeet      mnet.EquipSlot = "feet"
	SlotTrousers  mnet.EquipSlot = "trousers"
)

// WornSlots is the closed, ordered list of worn slot names. It rides on the
// wire in every equipment restatement so the client never holds a second copy
// of it. Read-only. Draw order on the client is scene-authored; this order is
// the wire restatement order.
var WornSlots = []mnet.EquipSlot{
	SlotHelmet, SlotLeftHand, SlotChest, SlotRightHand, SlotFeet, SlotTrousers,
}

// kindSlotsOf says which worn slots a kind occupies, one-handed kinds a single
// slot and two-handed kinds the left and right hands. A kind absent from the
// table cannot be worn, which is how acorn is refused: a lookup that misses,
// not a rule naming the kinds that are not wearable. Adding a wearable kind is
// one entry here; every slot it names must already be in WornSlots.
// Handedness is the exclusivity mechanism (PROTOCOL.md, "Handedness", M7b).
var kindSlotsOf = map[string][]mnet.EquipSlot{
	KindAxe:             {SlotRightHand},
	KindSword:           {SlotRightHand},
	KindStaff:           {SlotLeftHand, SlotRightHand},
	KindBow:             {SlotLeftHand, SlotRightHand},
	KindLumberjackAxe:   {SlotLeftHand, SlotRightHand},
	KindPickaxe:         {SlotRightHand},
	KindProspectorBoots: {SlotFeet},
}

// DefaultJoinKit is what a joining player is given, in the order it is placed:
// one axe. Gathering produces logs, not an axe, so the kit does not earn one
// back. Tuning: ARM-81.
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
	// ErrNoRecipe: the slot's kind is not the consume kind a craft asked for.
	ErrNoRecipe = errors.New("game: no matching craft recipe")
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

// Crafted records one craft: Consume left bag slot From, Produce landed in bag
// slot Into.
type Crafted struct {
	From    int
	Into    int
	Consume string
	Produce string
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
	// the worn slot or slots its kind belongs in, completely or not at all. A
	// one-handed kind occupies one slot; a two-handed kind occupies both hand
	// slots. An occupied worn slot swaps: what was worn lands in the bag slot
	// just vacated, and a two-handed equip displaces both hands into that one
	// bag slot. Fails with ErrNoSuchPlayer, ErrNoSuchSlot, ErrEmptySlot, or
	// ErrNotEquippable.
	EquipInventorySlot(player mnet.PlayerID, slot int) (Equipped, error)

	// UnequipWornSlot moves whatever is in one of a player's worn slots into the
	// lowest free slot of their inventory, completely or not at all. Unequipping
	// either hand of a two-handed kind clears both hands into the lowest free
	// slot as one move, because the kind is worn across both. Fails with
	// ErrNoSuchPlayer, ErrNoSuchWornSlot, ErrEmptyWornSlot, or ErrInventoryFull.
	UnequipWornSlot(player mnet.PlayerID, slot mnet.EquipSlot) (Unequipped, error)

	// CraftInventorySlot consumes consumeKind from slot and places produceKind
	// in the lowest free bag slot, completely or not at all. Room is checked
	// before the consume (PROTOCOL.md, "Crafting"). Fails with ErrNoSuchPlayer,
	// ErrNoSuchSlot, ErrEmptySlot, ErrNoRecipe, or ErrInventoryFull.
	CraftInventorySlot(player mnet.PlayerID, slot int, consumeKind, produceKind string) (Crafted, error)

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
	worn, wearable := kindSlotsOf[kind]
	if !wearable {
		return Equipped{}, fmt.Errorf("equip %q from slot %d for player %d: %w", kind, slot, player, ErrNotEquippable)
	}

	// The exchange, and the reason this is one method rather than a get and a
	// put. Whatever was worn takes the bag slot the new item is leaving, so a
	// swap needs no free slot and cannot fail for want of one. A two-handed
	// kind displaces both hands with the right-hand item surviving into the
	// bag slot and the left-hand one lost to the swap, exactly as PROTOCOL.md's
	// "Handedness" describes.
	//
	// Handedness couples the hand slots into one exchange: the worn state ends
	// where the displaced kind was and starts where the new kind goes. Clear
	// the slots the displaced kind held, then write the new kind into the
	// slots it takes. A one-handed kind over a two-handed one frees the hand
	// the two-handed one vacated; a two-handed kind over a one-handed one
	// fills the second hand; an offhand is left alone unless the displaced
	// kind held it.
	primary := worn[len(worn)-1]
	displaced := held.worn[primary]
	held.bag[slot] = displaced
	if displaced != "" {
		if prev, known := kindSlotsOf[displaced]; known {
			for _, w := range prev {
				delete(held.worn, w)
			}
		}
	}
	for _, w := range worn {
		held.worn[w] = kind
	}

	return Equipped{Worn: worn[0], Kind: kind, Bag: slot, Displaced: displaced}, nil
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

	// A two-handed kind is worn across both hands, so taking either hand off
	// clears both into the lowest free bag slot as one move; a hand cannot keep
	// half of it. One-handed kinds clear the one slot they occupy. The kind
	// came from a worn slot, so equip has installed it and it is in the table;
	// a miss here is an invariant break, not a refusal.
	worn, known := kindSlotsOf[kind]
	if !known {
		panic(fmt.Sprintf("game: unequip %q, a worn kind that is in no kind table", kind))
	}

	index, room := held.free()
	if !room {
		return Unequipped{}, fmt.Errorf("unequip %q for player %d: %w", slot, player, ErrInventoryFull)
	}

	for _, w := range worn {
		delete(held.worn, w)
	}
	held.bag[index] = kind

	return Unequipped{Worn: slot, Kind: kind, Bag: index}, nil
}

func (s *memStore) CraftInventorySlot(player mnet.PlayerID, slot int, consumeKind, produceKind string) (Crafted, error) {
	if consumeKind == "" || produceKind == "" {
		panic(fmt.Sprintf("game: craft with empty kind for player %d", player))
	}
	held, known := s.held[player]
	if !known {
		return Crafted{}, fmt.Errorf("craft slot %d for player %d: %w", slot, player, ErrNoSuchPlayer)
	}
	if slot < 0 || slot >= InventorySize {
		return Crafted{}, fmt.Errorf("craft slot %d for player %d: %w", slot, player, ErrNoSuchSlot)
	}
	kind := held.bag[slot]
	if kind == "" {
		return Crafted{}, fmt.Errorf("craft slot %d for player %d: %w", slot, player, ErrEmptySlot)
	}
	if kind != consumeKind {
		return Crafted{}, fmt.Errorf("craft %q from slot %d for player %d: %w", kind, slot, player, ErrNoRecipe)
	}
	if _, room := held.free(); !room {
		return Crafted{}, fmt.Errorf("craft slot %d for player %d: %w", slot, player, ErrInventoryFull)
	}

	held.bag[slot] = ""
	index, room := held.free()
	if !room {
		panic(fmt.Sprintf("game: craft freed slot %d for player %d and still found no room", slot, player))
	}
	held.bag[index] = produceKind

	return Crafted{From: slot, Into: index, Consume: consumeKind, Produce: produceKind}, nil
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
