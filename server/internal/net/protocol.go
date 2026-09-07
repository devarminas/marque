package net

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
)

type PlayerID int64

type Point [2]float64

func Pt(x, z float64) Point { return Point{x, z} }

func (p Point) X() float64 { return p[0] }

func (p Point) Z() float64 { return p[1] }

type ItemID int64

type NodeID int64

const (
	NodeFull     = "full"
	NodeDepleted = "depleted"
)

type Seq int64

type EquipSlot string

const (
	MsgMoveTo  = "move_to"
	MsgMove    = "move"
	MsgPickup  = "pickup"
	MsgDrop    = "drop"
	MsgEquip   = "equip"
	MsgUnequip = "unequip"
	MsgGather  = "gather"
	MsgUse     = "use"
	MsgAttack  = "attack"
	MsgRespawn = "respawn"
	MsgCast    = "cast"
)

type PlayerState struct {
	ID      PlayerID `json:"id"`
	X       float64  `json:"x"`
	Z       float64  `json:"z"`
	HP      int      `json:"hp"`
	MaxHP   int      `json:"max_hp"`
	Mana    int      `json:"mana"`
	MaxMana int      `json:"max_mana"`
}

type ItemState struct {
	ID   ItemID  `json:"id"`
	Kind string  `json:"kind"`
	X    float64 `json:"x"`
	Z    float64 `json:"z"`
}

type NodeState struct {
	ID    NodeID  `json:"id"`
	Kind  string  `json:"kind"`
	Skill string  `json:"skill,omitempty"`
	X     float64 `json:"x"`
	Z     float64 `json:"z"`
	State string  `json:"state"`
}

type NpcState struct {
	ID      PlayerID `json:"id"`
	Kind    string   `json:"kind"`
	Faction string   `json:"faction"`
	X       float64  `json:"x"`
	Z       float64  `json:"z"`
	HP      int      `json:"hp"`
	MaxHP   int      `json:"max_hp"`
}

type InventorySlot struct {
	Slot int    `json:"slot"`
	Kind string `json:"kind"`
}

type EquipmentSlot struct {
	Slot EquipSlot `json:"slot"`
	Kind string    `json:"kind"`
}

type ServerMessage interface{ isServerMessage() }

type Welcome struct {
	You            PlayerID      `json:"you"`
	Session        string        `json:"session"`
	LastSeq        Seq           `json:"last_seq"`
	TickMS         int           `json:"tick_ms"`
	Tick           int64         `json:"tick"`
	HeartbeatTicks int           `json:"heartbeat_ticks,omitempty"`
	Players        []PlayerState `json:"players"`
	Items          []ItemState   `json:"items"`
	Nodes          []NodeState   `json:"nodes"`
	Npcs           []NpcState   `json:"npcs"`
}

type Spawn PlayerState

type Despawn struct {
	ID PlayerID `json:"id"`
}

type Path struct {
	ID        PlayerID `json:"id"`
	StartTick int64    `json:"start_tick"`
	Points    []Point  `json:"points"`
	Speed     float64  `json:"speed"`
}

type Error struct {
	Re  string `json:"re,omitempty"`
	Msg string `json:"msg"`
}

type ItemSpawn ItemState

type ItemDespawn struct {
	ID ItemID `json:"id"`
}

type NodeSpawn NodeState

type NodeDespawn struct {
	ID NodeID `json:"id"`
}

type NodeUpdate NodeState

type Inventory struct {
	Size  int             `json:"size"`
	Slots []InventorySlot `json:"slots"`
}

type Equipment struct {
	Worn  []EquipSlot     `json:"worn"`
	Slots []EquipmentSlot `json:"slots"`
}

type NamedSlot struct {
	Slot string `json:"slot"`
	Kind string `json:"kind"`
}

type ClassMissing struct {
	Slots []NamedSlot `json:"slots,omitempty"`
	Tools []string    `json:"tools,omitempty"`
}

type Class struct {
	Player  PlayerID     `json:"player"`
	Class   string       `json:"class"`
	Missing ClassMissing `json:"missing,omitempty"`
}

type SkillXP struct {
	ID    string `json:"id"`
	XP    int64  `json:"xp"`
	Level int    `json:"level"`
}

type Skills struct {
	Player PlayerID  `json:"player"`
	Skills []SkillXP `json:"skills"`
}

type Tick struct {
	T int64 `json:"t"`
}

type HP struct {
	ID    PlayerID `json:"id"`
	HP    int      `json:"hp"`
	MaxHP int      `json:"max_hp"`
}

type Mana struct {
	ID      PlayerID `json:"id"`
	Mana    int      `json:"mana"`
	MaxMana int      `json:"max_mana"`
}

func (Welcome) isServerMessage()     {}
func (Spawn) isServerMessage()       {}
func (Despawn) isServerMessage()     {}
func (Path) isServerMessage()        {}
func (Error) isServerMessage()       {}
func (ItemSpawn) isServerMessage()   {}
func (ItemDespawn) isServerMessage() {}
func (NodeSpawn) isServerMessage()   {}
func (NodeDespawn) isServerMessage() {}
func (NodeUpdate) isServerMessage()  {}
func (Inventory) isServerMessage()   {}
func (Equipment) isServerMessage()   {}
func (Class) isServerMessage()       {}
func (Skills) isServerMessage()      {}
func (Tick) isServerMessage()        {}
func (HP) isServerMessage()          {}
func (Mana) isServerMessage()        {}

type ClientMessage interface {
	isClientMessage()
	Name() string
}

type MoveTo struct {
	X float64 `json:"x"`
	Z float64 `json:"z"`
}

type Move struct {
	DX float64 `json:"dx"`
	DZ float64 `json:"dz"`
}

type Pickup struct {
	Item ItemID `json:"item"`
}

type Drop struct {
	Slot int `json:"slot"`
}

type Equip struct {
	Slot int `json:"slot"`
}

type Unequip struct {
	Worn EquipSlot `json:"worn"`
}

type Gather struct {
	Node NodeID `json:"node"`
}

type Use struct {
	Slot int `json:"slot"`
	On   int `json:"on"`
}

type Attack struct {
	Player PlayerID `json:"player"`
}

type Respawn struct{}

type Cast struct {
	Ability string
	Player  PlayerID
}

func (MoveTo) isClientMessage()  {}
func (Move) isClientMessage()    {}
func (Pickup) isClientMessage()  {}
func (Drop) isClientMessage()    {}
func (Equip) isClientMessage()   {}
func (Unequip) isClientMessage() {}
func (Gather) isClientMessage()  {}
func (Use) isClientMessage()     {}
func (Attack) isClientMessage()  {}
func (Respawn) isClientMessage() {}
func (Cast) isClientMessage()    {}

func (MoveTo) Name() string  { return MsgMoveTo }
func (Move) Name() string    { return MsgMove }
func (Pickup) Name() string  { return MsgPickup }
func (Drop) Name() string    { return MsgDrop }
func (Equip) Name() string   { return MsgEquip }
func (Unequip) Name() string { return MsgUnequip }
func (Gather) Name() string  { return MsgGather }
func (Use) Name() string     { return MsgUse }
func (Attack) Name() string  { return MsgAttack }
func (Respawn) Name() string { return MsgRespawn }
func (Cast) Name() string    { return MsgCast }

type serverEnvelope struct {
	Welcome     *Welcome     `json:"welcome,omitempty"`
	Spawn       *Spawn       `json:"spawn,omitempty"`
	Despawn     *Despawn     `json:"despawn,omitempty"`
	Path        *Path        `json:"path,omitempty"`
	Error       *Error       `json:"error,omitempty"`
	ItemSpawn   *ItemSpawn   `json:"item_spawn,omitempty"`
	ItemDespawn *ItemDespawn `json:"item_despawn,omitempty"`
	NodeSpawn   *NodeSpawn   `json:"node_spawn,omitempty"`
	NodeDespawn *NodeDespawn `json:"node_despawn,omitempty"`
	NodeState   *NodeUpdate  `json:"node_state,omitempty"`
	Inventory   *Inventory   `json:"inventory,omitempty"`
	Equipment   *Equipment   `json:"equipment,omitempty"`
	Class       *Class       `json:"class,omitempty"`
	Skills      *Skills      `json:"skills,omitempty"`
	Tick        *Tick        `json:"tick,omitempty"`
	HP          *HP          `json:"hp,omitempty"`
	Mana        *Mana        `json:"mana,omitempty"`
}

func Encode(m ServerMessage) ([]byte, error) {
	var env serverEnvelope
	switch v := m.(type) {
	case Welcome:
		env.Welcome = &v
	case Spawn:
		env.Spawn = &v
	case Despawn:
		env.Despawn = &v
	case Path:
		env.Path = &v
	case Error:
		env.Error = &v
	case ItemSpawn:
		env.ItemSpawn = &v
	case ItemDespawn:
		env.ItemDespawn = &v
	case NodeSpawn:
		env.NodeSpawn = &v
	case NodeDespawn:
		env.NodeDespawn = &v
	case NodeUpdate:
		env.NodeState = &v
	case Inventory:
		env.Inventory = &v
	case Equipment:
		env.Equipment = &v
	case Class:
		env.Class = &v
	case Skills:
		env.Skills = &v
	case Tick:
		env.Tick = &v
	case HP:
		env.HP = &v
	case Mana:
		env.Mana = &v
	default:
		return nil, fmt.Errorf("net: encode: unhandled server message %T", m)
	}
	b, err := json.Marshal(env)
	if err != nil {
		return nil, fmt.Errorf("net: encode %T: %w", m, err)
	}
	return b, nil
}

type RejectReason string

const (
	ReasonMalformedJSON RejectReason = "malformed_json"
	ReasonProtocolError RejectReason = "protocol_error"
	ReasonUnknownMessage RejectReason = "unknown_message"
	ReasonMissingField RejectReason = "missing_field"
	ReasonNonFinite RejectReason = "non_finite"
	ReasonOutOfBounds RejectReason = "out_of_bounds"
	ReasonDegenerate RejectReason = "degenerate"
	ReasonUnknownItem RejectReason = "unknown_item"
	ReasonNoSuchSlot RejectReason = "no_such_slot"
	ReasonEmptySlot RejectReason = "empty_slot"
	ReasonNotEquippable RejectReason = "not_equippable"
	ReasonNoSuchWornSlot RejectReason = "no_such_worn_slot"
	ReasonEmptyWornSlot RejectReason = "empty_worn_slot"
	ReasonInventoryFull RejectReason = "inventory_full"
	ReasonUnknownNode RejectReason = "unknown_node"
	ReasonNodeDepleted RejectReason = "node_depleted"
	ReasonNeedsClass RejectReason = "needs_class"
	ReasonNoRecipe RejectReason = "no_recipe"
	ReasonUnknownPlayer RejectReason = "unknown_player"
	ReasonSelf RejectReason = "self"
	ReasonTargetDead RejectReason = "target_dead"
	ReasonDead RejectReason = "dead"
	ReasonNotDead RejectReason = "not_dead"
	ReasonUnknownAbility RejectReason = "unknown_ability"
	ReasonNoTarget RejectReason = "no_target"
	ReasonWrongTarget RejectReason = "wrong_target"
	ReasonInsufficientMana RejectReason = "insufficient_mana"
	ReasonOutOfRange RejectReason = "out_of_range"
	ReasonUnknownSender RejectReason = "unknown_sender"
	ReasonBinaryFrame RejectReason = "binary_frame"
)

type Disposition int

const (
	Ignore Disposition = iota
	ReplyError
	ReplyErrorAndClose
)

type RejectError struct {
	Reason      RejectReason
	Detail      string
	Re          string
	Disposition Disposition
}

func (e *RejectError) Error() string {
	if e.Detail == "" {
		return string(e.Reason)
	}
	return string(e.Reason) + ": " + e.Detail
}

func Rejection(err error) (*RejectError, bool) {
	var re *RejectError
	if errors.As(err, &re) {
		return re, true
	}
	return nil, false
}

func rejectIntent(reason RejectReason, re, format string, args ...any) error {
	return &RejectError{
		Reason:      reason,
		Detail:      fmt.Sprintf(format, args...),
		Re:          re,
		Disposition: ReplyError,
	}
}

type moveToWire struct {
	X *float64 `json:"x"`
	Z *float64 `json:"z"`
}

type moveWire struct {
	DX *float64 `json:"dx"`
	DZ *float64 `json:"dz"`
}

type pickupWire struct {
	Item *ItemID `json:"item"`
}

type dropWire struct {
	Slot *int `json:"slot"`
}

type equipWire struct {
	Slot *int `json:"slot"`
}

type unequipWire struct {
	Worn *EquipSlot `json:"worn"`
}

type gatherWire struct {
	Node *NodeID `json:"node"`
}

type useWire struct {
	Slot *int `json:"slot"`
	On   *int `json:"on"`
}

type attackWire struct {
	Player *PlayerID `json:"player"`
}

type castWire struct {
	Ability *string   `json:"ability"`
	Player  *PlayerID `json:"player"`
}

type seqWire struct {
	Seq *int64 `json:"seq"`
}

func Decode(frame []byte) (ClientMessage, Seq, error) {
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(frame, &keys); err != nil {
		return nil, 0, &RejectError{
			Reason:      ReasonMalformedJSON,
			Detail:      fmt.Sprintf("not a JSON object: %v", err),
			Disposition: ReplyError,
		}
	}
	if len(keys) != 1 {
		return nil, 0, &RejectError{
			Reason:      ReasonProtocolError,
			Detail:      fmt.Sprintf("expected exactly one message key, got %d", len(keys)),
			Disposition: ReplyErrorAndClose,
		}
	}

	for key, payload := range keys {
		var decodeBody func([]byte) (ClientMessage, error)
		switch key {
		case MsgMoveTo:
			decodeBody = decodeMoveTo
		case MsgMove:
			decodeBody = decodeMove
		case MsgPickup:
			decodeBody = decodePickup
		case MsgDrop:
			decodeBody = decodeDrop
		case MsgEquip:
			decodeBody = decodeEquip
		case MsgUnequip:
			decodeBody = decodeUnequip
		case MsgGather:
			decodeBody = decodeGather
		case MsgUse:
			decodeBody = decodeUse
		case MsgAttack:
			decodeBody = decodeAttack
		case MsgRespawn:
			decodeBody = decodeRespawn
		case MsgCast:
			decodeBody = decodeCast
		default:
			return nil, 0, &RejectError{
				Reason:      ReasonUnknownMessage,
				Detail:      fmt.Sprintf("unknown message %q", key),
				Re:          key,
				Disposition: Ignore,
			}
		}

		seq, err := decodeSeq(payload, key)
		if err != nil {
			return nil, 0, err
		}
		msg, err := decodeBody(payload)
		if err != nil {
			return nil, seq, err
		}
		return msg, seq, nil
	}
	panic("unreachable: map of length 1 yielded no entries")
}

func decodeSeq(payload []byte, re string) (Seq, error) {
	var wire seqWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return 0, rejectIntent(ReasonMalformedJSON, re,
			"%s: seq must be a JSON integer of at least 1: %v", re, err)
	}
	if wire.Seq == nil {
		return 0, nil
	}
	if *wire.Seq < 1 {
		return 0, rejectIntent(ReasonMalformedJSON, re,
			"%s: seq must be a JSON integer of at least 1, got %d", re, *wire.Seq)
	}
	return Seq(*wire.Seq), nil
}

func decodeMoveTo(payload []byte) (ClientMessage, error) {
	var wire moveToWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgMoveTo, "move_to: %v", err)
	}
	if wire.X == nil || wire.Z == nil {
		return nil, rejectIntent(ReasonMissingField, MsgMoveTo, "move_to needs both x and z")
	}
	if !finite(*wire.X) || !finite(*wire.Z) {
		return nil, rejectIntent(ReasonNonFinite, MsgMoveTo, "move_to coordinates must be finite")
	}
	return MoveTo{X: *wire.X, Z: *wire.Z}, nil
}

func decodeMove(payload []byte) (ClientMessage, error) {
	var wire moveWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgMove, "move: %v", err)
	}
	if wire.DX == nil || wire.DZ == nil {
		return nil, rejectIntent(ReasonMissingField, MsgMove, "move needs both dx and dz")
	}
	if !finite(*wire.DX) || !finite(*wire.DZ) {
		return nil, rejectIntent(ReasonNonFinite, MsgMove, "move components must be finite")
	}
	return Move{DX: *wire.DX, DZ: *wire.DZ}, nil
}

func decodePickup(payload []byte) (ClientMessage, error) {
	var wire pickupWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgPickup, "pickup: %v", err)
	}
	if wire.Item == nil {
		return nil, rejectIntent(ReasonMissingField, MsgPickup, "pickup needs an item id")
	}
	return Pickup{Item: *wire.Item}, nil
}

func decodeDrop(payload []byte) (ClientMessage, error) {
	var wire dropWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgDrop, "drop: %v", err)
	}
	if wire.Slot == nil {
		return nil, rejectIntent(ReasonMissingField, MsgDrop, "drop needs a slot index")
	}
	return Drop{Slot: *wire.Slot}, nil
}

func decodeEquip(payload []byte) (ClientMessage, error) {
	var wire equipWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgEquip, "equip: %v", err)
	}
	if wire.Slot == nil {
		return nil, rejectIntent(ReasonMissingField, MsgEquip, "equip needs a slot index")
	}
	return Equip{Slot: *wire.Slot}, nil
}

func decodeUnequip(payload []byte) (ClientMessage, error) {
	var wire unequipWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgUnequip, "unequip: %v", err)
	}
	if wire.Worn == nil {
		return nil, rejectIntent(ReasonMissingField, MsgUnequip, "unequip needs a worn slot name")
	}
	return Unequip{Worn: *wire.Worn}, nil
}

func decodeGather(payload []byte) (ClientMessage, error) {
	var wire gatherWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgGather, "gather: %v", err)
	}
	if wire.Node == nil {
		return nil, rejectIntent(ReasonMissingField, MsgGather, "gather needs a node id")
	}
	return Gather{Node: *wire.Node}, nil
}

func decodeUse(payload []byte) (ClientMessage, error) {
	var wire useWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgUse, "use: %v", err)
	}
	if wire.Slot == nil || wire.On == nil {
		return nil, rejectIntent(ReasonMissingField, MsgUse, "use needs both slot and on")
	}
	return Use{Slot: *wire.Slot, On: *wire.On}, nil
}

func decodeAttack(payload []byte) (ClientMessage, error) {
	var wire attackWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgAttack, "attack: %v", err)
	}
	if wire.Player == nil {
		return nil, rejectIntent(ReasonMissingField, MsgAttack, "attack needs a player id")
	}
	return Attack{Player: *wire.Player}, nil
}

func decodeRespawn(payload []byte) (ClientMessage, error) {
	var wire map[string]json.RawMessage
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgRespawn, "respawn: %v", err)
	}
	return Respawn{}, nil
}

func decodeCast(payload []byte) (ClientMessage, error) {
	var wire castWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgCast, "cast: %v", err)
	}
	if wire.Ability == nil || strings.TrimSpace(*wire.Ability) == "" {
		return nil, rejectIntent(ReasonMissingField, MsgCast, "cast needs an ability id")
	}
	msg := Cast{Ability: strings.TrimSpace(*wire.Ability)}
	if wire.Player != nil {
		msg.Player = *wire.Player
	}
	return msg, nil
}

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }
