package game

import (
	"errors"
	"fmt"

	mnet "github.com/devarminas/marque/server/internal/net"
)

const InventorySize = 28

const (
	KindAcorn           = "acorn"
	KindStick           = "stick"
	KindSword           = "sword"
	KindStaff           = "staff"
	KindBow             = "bow"
	KindLumberjackAxe   = "lumberjack_axe"
	KindPickaxe         = "pickaxe"
	KindProspectorBoots = "prospector_boots"
	KindShield          = "shield"
)

const (
	SlotHelmet    mnet.EquipSlot = "helmet"
	SlotLeftHand  mnet.EquipSlot = "left hand"
	SlotChest     mnet.EquipSlot = "chest"
	SlotRightHand mnet.EquipSlot = "right hand"
	SlotFeet      mnet.EquipSlot = "feet"
	SlotTrousers  mnet.EquipSlot = "trousers"
)

var WornSlots = []mnet.EquipSlot{
	SlotHelmet, SlotLeftHand, SlotChest, SlotRightHand, SlotFeet, SlotTrousers,
}

var DefaultJoinKit []string

var (
	ErrNoSuchItem = errors.New("game: no such ground item")
	ErrInventoryFull = errors.New("game: inventory is full")
	ErrNoSuchSlot = errors.New("game: no such inventory slot")
	ErrEmptySlot = errors.New("game: inventory slot is empty")
	ErrNoSuchPlayer = errors.New("game: no such player")
	ErrNotEquippable = errors.New("game: that kind cannot be worn")
	ErrNoSuchWornSlot = errors.New("game: no such worn slot")
	ErrEmptyWornSlot = errors.New("game: worn slot is empty")
	ErrNoRecipe = errors.New("game: no matching craft recipe")
)

type GroundItem struct {
	ID   mnet.ItemID
	Kind string
	X    float64
	Z    float64
}

type Slot struct {
	Index int
	Kind  string
}

type WornSlot struct {
	Slot mnet.EquipSlot
	Kind string
}

type Equipped struct {
	Worn      mnet.EquipSlot
	Kind      string
	Bag       int
	Displaced string
}

type Unequipped struct {
	Worn mnet.EquipSlot
	Kind string
	Bag  int
}

type Crafted struct {
	From    int
	Into    int
	Consume string
	Produce string
}

type Store interface {
	AddPlayer(mnet.PlayerID)

	RemovePlayer(mnet.PlayerID)

	SpawnGroundItem(kind string, x, z float64) GroundItem

	GroundItems() []GroundItem

	GroundItem(mnet.ItemID) (GroundItem, bool)

	TakeGroundItem(mnet.ItemID, mnet.PlayerID) (Slot, error)

	DropInventorySlot(player mnet.PlayerID, slot int, x, z float64) (GroundItem, error)

	SpawnInventoryItem(player mnet.PlayerID, kind string) (Slot, error)

	EquipInventorySlot(player mnet.PlayerID, slot int) (Equipped, error)

	UnequipWornSlot(player mnet.PlayerID, slot mnet.EquipSlot) (Unequipped, error)

	CraftInventorySlot(player mnet.PlayerID, slot int, consumeKind, produceKind string) (Crafted, error)

	Inventory(mnet.PlayerID) []Slot

	Worn(mnet.PlayerID) []WornSlot
}

type playerItems struct {
	bag  [InventorySize]string
	worn map[mnet.EquipSlot]string
}

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

	wearables map[string][]mnet.EquipSlot

	ground map[mnet.ItemID]GroundItem
	order  []mnet.ItemID

	held map[mnet.PlayerID]*playerItems
}

var NoWearables = map[string][]mnet.EquipSlot{}

func NewMemoryStore(wearables map[string][]mnet.EquipSlot) Store {
	if wearables == nil {
		panic("game: NewMemoryStore: nil wearables (pass NoWearables for bag-only)")
	}
	return &memStore{
		wearables: wearables,
		ground:    make(map[mnet.ItemID]GroundItem),
		held:      make(map[mnet.PlayerID]*playerItems),
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
	worn, wearable := s.wearables[kind]
	if !wearable {
		return Equipped{}, fmt.Errorf("equip %q from slot %d for player %d: %w", kind, slot, player, ErrNotEquippable)
	}

	primary := worn[len(worn)-1]
	displaced := held.worn[primary]
	held.bag[slot] = displaced
	if displaced != "" {
		if prev, known := s.wearables[displaced]; known {
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

	worn, known := s.wearables[kind]
	if !known {
		panic(fmt.Sprintf("game: unequip %q, a worn kind that is in no wearables map", kind))
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
