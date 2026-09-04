// Package net carries the Marque wire protocol and the WebSocket hub that
// speaks it. It knows nothing about the game. PROTOCOL.md at the repository
// root is the contract.
package net

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
)

// PlayerID identifies a connected player for the lifetime of one server
// process. Ids are assigned sequentially from 1 and are never reused.
type PlayerID int64

// Point is one ground-plane waypoint, encoded as [x, z].
type Point [2]float64

// Pt builds a Point from ground-plane coordinates.
func Pt(x, z float64) Point { return Point{x, z} }

// X returns the point's x coordinate.
func (p Point) X() float64 { return p[0] }

// Z returns the point's z coordinate.
func (p Point) Z() float64 { return p[1] }

// ItemID identifies one item for the lifetime of one server process: a separate
// sequence from PlayerID, assigned from 1, never reused (PROTOCOL.md, "Entity
// naming").
type ItemID int64

// Seq is one intent's sequence number (PROTOCOL.md, "Sequence numbers"). Zero
// means the frame carried none.
type Seq int64

// EquipSlot names one worn equipment slot. Worn slots are named rather than
// indexed, which is the whole reason `unequip` says "worn" where `drop` and
// `equip` say "slot" (PROTOCOL.md, "Worn slots").
type EquipSlot string

// Client-to-server message names. Each is the key in the envelope and the value
// of an error's "re" field.
const (
	MsgMoveTo  = "move_to"
	MsgPickup  = "pickup"
	MsgDrop    = "drop"
	MsgEquip   = "equip"
	MsgUnequip = "unequip"
)

// PlayerState is one player's position, as it appears inside welcome.
type PlayerState struct {
	ID PlayerID `json:"id"`
	X  float64  `json:"x"`
	Z  float64  `json:"z"`
}

// ItemState is one ground item, as it appears inside welcome and item_spawn.
type ItemState struct {
	ID   ItemID  `json:"id"`
	Kind string  `json:"kind"`
	X    float64 `json:"x"`
	Z    float64 `json:"z"`
}

// InventorySlot is one occupied slot of one player's inventory; empty slots are
// absent from the list (PROTOCOL.md, "inventory").
type InventorySlot struct {
	Slot int    `json:"slot"`
	Kind string `json:"kind"`
}

// EquipmentSlot is one occupied worn slot of one player's equipment; empty slots
// are absent from the list (PROTOCOL.md, "equipment").
type EquipmentSlot struct {
	Slot EquipSlot `json:"slot"`
	Kind string    `json:"kind"`
}

// ServerMessage is one message the server can send. Every frame is a JSON
// object with exactly one key, which names the message.
type ServerMessage interface{ isServerMessage() }

// Welcome is the first message a client receives: You and Session name the
// receiver, LastSeq is the highest seq accepted from it, and Players and Items
// are the world as of Tick (PROTOCOL.md, "welcome").
type Welcome struct {
	You            PlayerID      `json:"you"`
	Session        string        `json:"session"`
	LastSeq        Seq           `json:"last_seq"`
	TickMS         int           `json:"tick_ms"`
	Tick           int64         `json:"tick"`
	HeartbeatTicks int           `json:"heartbeat_ticks,omitempty"`
	Players        []PlayerState `json:"players"`
	Items          []ItemState   `json:"items"`
}

// Spawn announces a player who just joined. Broadcast to everyone except the
// joining player, who learns about itself through welcome.
type Spawn PlayerState

// Despawn announces a player who left. Broadcast to everyone except the leaver.
type Despawn struct {
	ID PlayerID `json:"id"`
}

// Path assigns a polyline to a player; broadcast to everyone including the
// mover. Points[0] is the player's position at StartTick, Points is never
// empty, and Speed is world units per second (PROTOCOL.md, "path").
type Path struct {
	ID        PlayerID `json:"id"`
	StartTick int64    `json:"start_tick"`
	Points    []Point  `json:"points"`
	Speed     float64  `json:"speed"`
}

// Error tells one client that what it just sent was refused. Re names the
// message, omitted when unattributable; Msg is for humans, not for branching.
type Error struct {
	Re  string `json:"re,omitempty"`
	Msg string `json:"msg"`
}

// ItemSpawn announces an item that has appeared on the ground. Broadcast to
// everyone including the player who caused it.
type ItemSpawn ItemState

// ItemDespawn announces an item that has left the ground. Broadcast to everyone
// including the player who caused it, for ItemSpawn's reason.
type ItemDespawn struct {
	ID ItemID `json:"id"`
}

// Inventory is one player's whole inventory, sent to that player only. Size is
// the slot count; Slots lists the occupied slots.
type Inventory struct {
	Size  int             `json:"size"`
	Slots []InventorySlot `json:"slots"`
}

// Equipment is one player's whole worn equipment, sent to that player only.
// Worn is the closed, ordered list of slot names this server has, which is
// Inventory.Size's analogue; Slots lists the occupied ones.
type Equipment struct {
	Worn  []EquipSlot     `json:"worn"`
	Slots []EquipmentSlot `json:"slots"`
}

// Tick is the server's clock heartbeat, broadcast every heartbeat_ticks ticks.
// T is the tick being stepped.
type Tick struct {
	T int64 `json:"t"`
}

func (Welcome) isServerMessage()     {}
func (Spawn) isServerMessage()       {}
func (Despawn) isServerMessage()     {}
func (Path) isServerMessage()        {}
func (Error) isServerMessage()       {}
func (ItemSpawn) isServerMessage()   {}
func (ItemDespawn) isServerMessage() {}
func (Inventory) isServerMessage()   {}
func (Equipment) isServerMessage()   {}
func (Tick) isServerMessage()        {}

// ClientMessage is one message a client can send: an intent, never a fact.
// Name is its wire name, the same string an error carries as "re".
type ClientMessage interface {
	isClientMessage()
	Name() string
}

// MoveTo is a click on the ground: the player wants to walk to (X, Z).
type MoveTo struct {
	X float64 `json:"x"`
	Z float64 `json:"z"`
}

// Pickup is a request to take the ground item with id Item.
type Pickup struct {
	Item ItemID `json:"item"`
}

// Drop is a request to drop whatever is in the sender's inventory slot Slot at
// the player's feet (PROTOCOL.md, "drop").
type Drop struct {
	Slot int `json:"slot"`
}

// Equip is a request to wear whatever is in the sender's inventory slot Slot.
// The intent names a bag index and never a worn slot: the server resolves the
// destination from the kind (PROTOCOL.md, "equip").
type Equip struct {
	Slot int `json:"slot"`
}

// Unequip is a request to take off whatever is in worn slot Worn and put it
// back in the bag (PROTOCOL.md, "unequip").
type Unequip struct {
	Worn EquipSlot `json:"worn"`
}

func (MoveTo) isClientMessage()  {}
func (Pickup) isClientMessage()  {}
func (Drop) isClientMessage()    {}
func (Equip) isClientMessage()   {}
func (Unequip) isClientMessage() {}

func (MoveTo) Name() string  { return MsgMoveTo }
func (Pickup) Name() string  { return MsgPickup }
func (Drop) Name() string    { return MsgDrop }
func (Equip) Name() string   { return MsgEquip }
func (Unequip) Name() string { return MsgUnequip }

type serverEnvelope struct {
	Welcome     *Welcome     `json:"welcome,omitempty"`
	Spawn       *Spawn       `json:"spawn,omitempty"`
	Despawn     *Despawn     `json:"despawn,omitempty"`
	Path        *Path        `json:"path,omitempty"`
	Error       *Error       `json:"error,omitempty"`
	ItemSpawn   *ItemSpawn   `json:"item_spawn,omitempty"`
	ItemDespawn *ItemDespawn `json:"item_despawn,omitempty"`
	Inventory   *Inventory   `json:"inventory,omitempty"`
	Equipment   *Equipment   `json:"equipment,omitempty"`
	Tick        *Tick        `json:"tick,omitempty"`
}

// Encode renders one server message as a single WebSocket text frame payload.
// It fails only on a value JSON cannot represent, such as a non-finite
// coordinate.
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
	case Inventory:
		env.Inventory = &v
	case Equipment:
		env.Equipment = &v
	case Tick:
		env.Tick = &v
	default:
		return nil, fmt.Errorf("net: encode: unhandled server message %T", m)
	}
	b, err := json.Marshal(env)
	if err != nil {
		return nil, fmt.Errorf("net: encode %T: %w", m, err)
	}
	return b, nil
}

// RejectReason is the closed set of reasons an inbound frame is refused. The
// values are log field contents and test assertions, so they are stable.
type RejectReason string

const (
	// ReasonMalformedJSON: the frame is not a JSON object, or a known field has
	// the wrong type.
	ReasonMalformedJSON RejectReason = "malformed_json"
	// ReasonProtocolError: zero or more than one top-level key.
	ReasonProtocolError RejectReason = "protocol_error"
	// ReasonUnknownMessage: one top-level key naming a message this server does
	// not know. Logged and ignored.
	ReasonUnknownMessage RejectReason = "unknown_message"
	// ReasonMissingField: a required field was absent.
	ReasonMissingField RejectReason = "missing_field"
	// ReasonNonFinite: a coordinate decoded to NaN or +/-Inf.
	ReasonNonFinite RejectReason = "non_finite"
	// ReasonOutOfBounds: a destination outside the world.
	ReasonOutOfBounds RejectReason = "out_of_bounds"
	// ReasonDegenerate: a path too short to assign.
	ReasonDegenerate RejectReason = "degenerate"
	// ReasonUnknownItem: a pickup naming no live ground item, whether stale,
	// taken, or invented (PROTOCOL.md, "Pickup").
	ReasonUnknownItem RejectReason = "unknown_item"
	// ReasonNoSuchSlot: a drop naming an index outside the inventory.
	ReasonNoSuchSlot RejectReason = "no_such_slot"
	// ReasonEmptySlot: a drop naming a legal index that holds nothing.
	ReasonEmptySlot RejectReason = "empty_slot"
	// ReasonNotEquippable: an equip naming a slot whose kind belongs to no worn
	// slot (PROTOCOL.md, "equip").
	ReasonNotEquippable RejectReason = "not_equippable"
	// ReasonNoSuchWornSlot: an unequip naming a worn slot this server does not
	// have.
	ReasonNoSuchWornSlot RejectReason = "no_such_worn_slot"
	// ReasonEmptyWornSlot: an unequip naming a worn slot that holds nothing.
	ReasonEmptyWornSlot RejectReason = "empty_worn_slot"
	// ReasonInventoryFull: an unequip with no free bag slot to put the item in.
	// A pickup that arrives at a full bag is not this: it fails on arrival
	// rather than on receipt, so it logs pickup_no_room and never reaches the
	// refusal path (PROTOCOL.md, "Log vocabulary", M3a).
	ReasonInventoryFull RejectReason = "inventory_full"
	// ReasonUnknownSender: a frame from a connection with no player.
	ReasonUnknownSender RejectReason = "unknown_sender"
	// ReasonBinaryFrame: a WebSocket binary frame.
	ReasonBinaryFrame RejectReason = "binary_frame"
)

// Disposition is what the server does about a refused frame, beyond logging it.
type Disposition int

const (
	// Ignore: log and carry on (PROTOCOL.md, "Compatibility").
	Ignore Disposition = iota
	// ReplyError: send the sender one error message. The connection survives.
	ReplyError
	// ReplyErrorAndClose: send the sender one error message, then close.
	ReplyErrorAndClose
)

// RejectError explains why a frame was refused. Reason goes in the event log,
// Detail becomes the error message's "msg", and Re names the message being
// rejected, empty when the frame could not be attributed to one.
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

// Rejection extracts the rejection from an error, or reports false if the error
// is not one.
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

// The wire types use pointer fields because encoding/json zero-fills an absent
// field, and absent must be rejected rather than read as 0.
type moveToWire struct {
	X *float64 `json:"x"`
	Z *float64 `json:"z"`
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

type seqWire struct {
	Seq *int64 `json:"seq"`
}

// Decode parses one inbound frame into its message and its sequence number.
// Every failure is a *RejectError. A seq the envelope accepted is returned even
// when the body is then refused (PROTOCOL.md, "Sequence numbers").
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
		case MsgPickup:
			decodeBody = decodePickup
		case MsgDrop:
			decodeBody = decodeDrop
		case MsgEquip:
			decodeBody = decodeEquip
		case MsgUnequip:
			decodeBody = decodeUnequip
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

// decodeSeq unmarshals into *int64 so a fractional, quoted, or overflowing seq
// fails as malformed; 0 is refused rather than read as absent.
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
	// Not DisallowUnknownFields: senders may add fields (PROTOCOL.md,
	// "Compatibility" rule 2).
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

// decodeUnequip guards the shape and not the membership: whether a name is one
// of this server's worn slots is the game's question, and it answers it with
// no_such_worn_slot. An empty string is a name nothing has, so it needs no case
// of its own here.
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

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }
