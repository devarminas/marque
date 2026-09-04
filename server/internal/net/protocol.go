// Package net carries the Marque wire protocol and the WebSocket hub that
// speaks it. It knows nothing about the game: no world, no tick, no movement
// rules. The game package imports this one, never the reverse.
//
// PROTOCOL.md at the repository root is the contract. If this code disagrees
// with that file, this code is wrong.
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
//
// The world is 3D but movement is not: y is the height of the ground at that
// point, the client derives it, and it never appears on the wire (PROTOCOL.md,
// "Coordinates").
type Point [2]float64

// Pt builds a Point from ground-plane coordinates.
func Pt(x, z float64) Point { return Point{x, z} }

// X returns the point's x coordinate.
func (p Point) X() float64 { return p[0] }

// Z returns the point's z coordinate.
func (p Point) Z() float64 { return p[1] }

// ItemID identifies one item for the lifetime of one server process.
//
// A separate sequence in a separate space from PlayerID: assigned from 1 as
// items enter the world, never reused, and never mixed with a player id
// (PROTOCOL.md, "Entity naming"). The distinct Go type is what stops one being
// passed where the other belongs, which is the cheapest bug in this protocol to
// write and one of the more expensive to find.
type ItemID int64

// Seq is one intent's sequence number, parsed once at the envelope and used by
// the game package to drop retries (PROTOCOL.md, "Sequence numbers").
//
// Zero means the frame carried none. Decode is the only constructor and it
// refuses anything below 1, so no legal Seq is ever 0.
type Seq int64

// Client-to-server message names. Each is the key in the envelope and the value
// of an error's "re" field.
const (
	MsgMoveTo = "move_to"
	MsgPickup = "pickup"
	MsgDrop   = "drop"
)

// PlayerState is one player's position, as it appears inside welcome.
type PlayerState struct {
	ID PlayerID `json:"id"`
	X  float64  `json:"x"`
	Z  float64  `json:"z"`
}

// ItemState is one ground item, as it appears inside welcome and item_spawn.
//
// Items use the id-carrying coordinate encoding, the same shape as PlayerState,
// rather than the packed [x, z] form path uses. Nothing about an item is a
// polyline (PROTOCOL.md, "Decoding notes for the Godot side").
//
// Kind is an item type name; M1 ships exactly one. A client that does not know
// a kind renders it magenta and keeps going, which is how content arrives
// without a client release.
type ItemState struct {
	ID   ItemID  `json:"id"`
	Kind string  `json:"kind"`
	X    float64 `json:"x"`
	Z    float64 `json:"z"`
}

// InventorySlot is one occupied slot of one player's inventory.
//
// Every entry carries its own index, because empty slots are absent from the
// list rather than present as null. A sparse list is smaller, and it keeps both
// ends off the question of how their JSON library spells a null inside an array
// (PROTOCOL.md, "inventory").
type InventorySlot struct {
	Slot int    `json:"slot"`
	Kind string `json:"kind"`
}

// ServerMessage is one message the server can send. The envelope is key-as-tag:
// every frame is a JSON object with exactly one key, and that key names the
// message. Implementations are closed to this package, so a message with two
// keys or none cannot be constructed.
type ServerMessage interface{ isServerMessage() }

// Welcome is the first message a client receives.
//
// You is the receiving client's own id. Players is every player in the world
// including itself, at their position as of Tick. TickMS tells the client the
// tick duration; Tick is the anchor every later StartTick is measured against.
//
// Items is every item lying on the ground as of the same tick. It is a sibling
// of Players because both describe the world. The joining player's own
// inventory is not here: it is private to one player rather than part of the
// world, and it arrives as a separate Inventory inside the same atomic step.
//
// Session is the receiving player's durable identity: 32 hex characters, the
// same across every resume of that player, and the thing a reconnecting client
// presents to be handed its own body back. It sits beside You because those two
// are what this message says about the receiver; everything else is the world.
//
// LastSeq is the highest sequence number this server has accepted from that
// player, 0 for one that has never sent a seq. There are no acks, so a resumed
// welcome is the only thing that tells a reconnecting client where its
// numbering got to; it therefore carries no omitempty and rides in every
// welcome, including as 0.
//
// HeartbeatTicks is the interval, in ticks, at which this server will send
// Tick. It is on the wire so the client uses the number it is told, never a
// second copy (PROTOCOL.md, "Clock"). Zero is omitted and means liveness is
// off, which is what every server before M2d said.
//
// Neither array carries omitempty, so an empty world encodes as "players":[]
// and "items":[] rather than dropping the key. Both must be handed to Encode
// non-nil: encoding/json writes a nil slice as null, and a client should not
// have to distinguish three spellings of "nothing there".
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

// Path assigns a polyline to a player. Broadcast to everyone including the
// mover.
//
// Points[0] is always the player's position at StartTick, so a client that
// processes the message late can still place the walker correctly by counting
// ticks. Speed is world units per second and is constant across the whole
// polyline. The server never sends per-tick positions.
//
// Points always has at least one element. A walker holds at the final point of
// its polyline, so a one-element path is a complete instruction to stand still
// there: that is how "stop walking" is expressed, and why no stop message
// exists (PROTOCOL.md, "path").
type Path struct {
	ID        PlayerID `json:"id"`
	StartTick int64    `json:"start_tick"`
	Points    []Point  `json:"points"`
	Speed     float64  `json:"speed"`
}

// Error tells one client that what it just sent was refused.
//
// Re names the message being rejected and is omitted when the frame was too
// malformed to attribute to one. Msg is for a human reading a log: not for
// display, and not for branching on.
//
// Without this a rejected intent is indistinguishable from packet loss, and the
// client debugging it has to read server logs across a language boundary.
type Error struct {
	Re  string `json:"re,omitempty"`
	Msg string `json:"msg"`
}

// ItemSpawn announces an item that has appeared on the ground.
//
// Broadcast to everyone including the player who caused it. That is Path's
// rule, not Spawn's: Spawn excludes the joining player because that player
// learns of itself from Welcome, and there is no equivalent here. A dropper who
// did not receive ItemSpawn would have to conjure the body from its own intent,
// which is the client inventing state the server never announced.
type ItemSpawn ItemState

// ItemDespawn announces an item that has left the ground. Broadcast to everyone
// including the player who caused it, for ItemSpawn's reason.
type ItemDespawn struct {
	ID ItemID `json:"id"`
}

// Inventory is one player's whole inventory, sent to that player only and never
// broadcast.
//
// A full restatement rather than a patch, matching Welcome's doctrine for the
// same reason: a restatement cannot drift, and twenty-eight slots is nothing on
// the wire. Slots lists only occupied slots and must be non-nil, so an empty
// inventory encodes as "slots":[].
//
// Size is how many slots the player has. It is on the wire so the client draws
// the grid it is told to draw rather than keeping a second copy of the number.
type Inventory struct {
	Size  int             `json:"size"`
	Slots []InventorySlot `json:"slots"`
}

// Tick is the server's clock heartbeat. Broadcast to every connected player
// at the top of a tick that is a multiple of the period welcome named as
// heartbeat_ticks.
//
// T is the tick being stepped. A reader aligns it against arrived.t and
// start_tick by arithmetic. There is no log line for this message.
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
func (Tick) isServerMessage()        {}

// ClientMessage is one message a client can send. Clients send intents, never
// facts (CLAUDE.md, "Architecture invariants").
//
// Name is the message's wire name, the same string Decode switched on and the
// same one an error about it carries as "re". It lives on the type so that a
// message added later cannot compile until it says its own name, which is what
// keeps the set from needing a second switch somewhere else.
type ClientMessage interface {
	isClientMessage()
	Name() string
}

// MoveTo is a click on the ground: the player wants to walk to (X, Z).
//
// It is an intent, not a position. The server decides whether the destination
// is legal and what path leads there.
type MoveTo struct {
	X float64 `json:"x"`
	Z float64 `json:"z"`
}

// Pickup is a request to take a ground item.
//
// Item is an item id, not a player id and not an inventory slot. It is an
// intent: the server decides whether that item exists, whether the player may
// have it, and when.
type Pickup struct {
	Item ItemID `json:"item"`
}

// Drop is a request to drop whatever is in one inventory slot at the player's
// feet.
//
// Slot is an index into the sender's own inventory, never an item id. The
// client names a position in its own cache and the server looks up what is
// actually there, which is the intents-never-facts rule at its most
// load-bearing: a client that could name the item id could name one it does not
// own (PROTOCOL.md, "drop").
//
// Whether the index is inside 0 to InventorySize-1, and whether anything is in
// it, are questions about world state and are not asked here. This package does
// not know how many slots a player has.
type Drop struct {
	Slot int `json:"slot"`
}

func (MoveTo) isClientMessage() {}
func (Pickup) isClientMessage() {}
func (Drop) isClientMessage()   {}

func (MoveTo) Name() string { return MsgMoveTo }
func (Pickup) Name() string { return MsgPickup }
func (Drop) Name() string   { return MsgDrop }

// serverEnvelope is the key-as-tag wrapper. Exactly one field is ever non-nil;
// Encode is the only thing that builds it.
type serverEnvelope struct {
	Welcome     *Welcome     `json:"welcome,omitempty"`
	Spawn       *Spawn       `json:"spawn,omitempty"`
	Despawn     *Despawn     `json:"despawn,omitempty"`
	Path        *Path        `json:"path,omitempty"`
	Error       *Error       `json:"error,omitempty"`
	ItemSpawn   *ItemSpawn   `json:"item_spawn,omitempty"`
	ItemDespawn *ItemDespawn `json:"item_despawn,omitempty"`
	Inventory   *Inventory   `json:"inventory,omitempty"`
	Tick        *Tick        `json:"tick,omitempty"`
}

// Encode renders one server message as a single WebSocket text frame payload.
//
// It fails only if a message carries a value JSON cannot represent, which for
// these types means a non-finite coordinate. Positions are validated finite
// before they enter world state, so a failure here is a bug upstream.
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
	// ReasonProtocolError: zero or more than one top-level key. Not a
	// compatibility problem, a malformed frame.
	ReasonProtocolError RejectReason = "protocol_error"
	// ReasonUnknownMessage: exactly one top-level key, naming a message this
	// server does not know. Logged loudly and ignored, so that a peer written
	// against a later protocol version does not break against this one.
	ReasonUnknownMessage RejectReason = "unknown_message"
	// ReasonMissingField: a required field was absent. Absent is not zero: a
	// move_to without z is a broken client, not a click on the z axis.
	ReasonMissingField RejectReason = "missing_field"
	// ReasonNonFinite: a coordinate decoded to NaN or +/-Inf. JSON has no
	// literal for either, so this is a backstop against a parser that saturates
	// an overflowing literal rather than failing on it.
	ReasonNonFinite RejectReason = "non_finite"
	// ReasonOutOfBounds: a destination outside the world. Raised by the game
	// package, which owns what the world is; named here so the whole set of
	// reasons is readable in one place.
	ReasonOutOfBounds RejectReason = "out_of_bounds"
	// ReasonDegenerate: a path whose total length is below the epsilon at which
	// the client's interpolator would divide by a segment length of zero.
	ReasonDegenerate RejectReason = "degenerate"
	// ReasonUnknownItem: a pickup naming no live ground item. Raised by the
	// game package, which owns what is lying in the world. One reason covers a
	// stale id, an id another player has already taken, and a fabricated one,
	// because the server must not tell a client which ids exist (PROTOCOL.md,
	// "Pickup").
	ReasonUnknownItem RejectReason = "unknown_item"
	// ReasonNoSuchSlot: a drop naming an index outside 0 to InventorySize-1.
	// Raised by the game package, which owns how many slots a player has.
	ReasonNoSuchSlot RejectReason = "no_such_slot"
	// ReasonEmptySlot: a drop naming a legal index that holds nothing.
	//
	// Deliberately a second reason rather than being folded into
	// ReasonNoSuchSlot, which is the opposite of what ReasonUnknownItem does
	// for pickup. The two situations differ in what they leak and in what they
	// mean. One pickup reason exists because the server must not tell a client
	// which item ids exist; a slot index leaks nothing, because the client is
	// told its own size in every inventory message and is told its own contents
	// as a full restatement. And the two are different diagnoses for a human
	// reading the log: an index outside the grid is a client that drew the
	// wrong grid, and an empty slot in range is an ordinary stale cache.
	ReasonEmptySlot RejectReason = "empty_slot"
	// ReasonUnknownSender: a frame from a connection with no player. Defensive:
	// the hub reports a connection before any of its frames.
	ReasonUnknownSender RejectReason = "unknown_sender"
	// ReasonBinaryFrame: a WebSocket binary frame. The protocol is text frames
	// carrying JSON, one object per frame.
	ReasonBinaryFrame RejectReason = "binary_frame"
)

// Disposition is what the server does about a refused frame, beyond logging it.
// The protocol fixes this per reason, so it travels with the rejection rather
// than being decided again at every call site.
type Disposition int

const (
	// Ignore: log loudly and carry on. Reserved for forward compatibility, the
	// one place the project's fail-fast doctrine is deliberately relaxed
	// (PROTOCOL.md, "Compatibility").
	Ignore Disposition = iota
	// ReplyError: send the sender one error message. The connection survives.
	ReplyError
	// ReplyErrorAndClose: send the sender one error message, then close.
	ReplyErrorAndClose
)

// RejectError explains why a frame was refused.
//
// Reason is machine-readable and goes in the event log. Detail is the human
// sentence that also becomes the error message's "msg". Re names the message
// being rejected, empty when the frame could not be attributed to one.
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

// rejectIntent builds the refusal for a frame that named a known message and
// then failed to decode. Re is always set, because the frame was attributable;
// the connection always survives, because a broken frame is a broken frame and
// not a broken client.
func rejectIntent(reason RejectReason, re, format string, args ...any) error {
	return &RejectError{
		Reason:      reason,
		Detail:      fmt.Sprintf(format, args...),
		Re:          re,
		Disposition: ReplyError,
	}
}

// moveToWire decodes move_to with pointer fields so that "absent" and "zero"
// stay distinguishable. encoding/json fills a missing field with the zero
// value, which would silently turn {"move_to":{"x":5}} into a click on the x
// axis; that is a decision, and this is where it is made: absent is rejected.
//
// Unknown fields are not listed and are therefore ignored, which is what lets
// senders add fields. seq is not listed here for that reason: it ships, but it
// is parsed at the envelope by seqWire and belongs to no one message.
type moveToWire struct {
	X *float64 `json:"x"`
	Z *float64 `json:"z"`
}

// pickupWire decodes pickup, with the same absent-is-not-zero rule as
// moveToWire. Zero is not a legal item id, so it would be caught either way,
// but "you sent no item" and "you sent item 0" are different bugs in the client
// and the server should say which one it saw.
type pickupWire struct {
	Item *ItemID `json:"item"`
}

// dropWire decodes drop, with the same absent-is-not-zero rule as moveToWire,
// and here it is load-bearing rather than merely tidy: slot 0 is a perfectly
// legal slot and the first one RuneScape's lowest-free rule fills. A missing
// field filled in with encoding/json's zero would turn {"drop":{}} into a drop
// of whatever the player is holding in their first slot.
type dropWire struct {
	Slot *int `json:"slot"`
}

// seqWire pulls seq out of whichever intent body carried it. It is specified
// once and parsed once, at the envelope, and no message body may give it a
// different meaning (PROTOCOL.md, "Sequence numbers").
//
// The pointer is what distinguishes an unsequenced frame from a seq of 0, which
// is a refusal rather than a synonym for absent.
type seqWire struct {
	Seq *int64 `json:"seq"`
}

// Decode parses one inbound frame into its message and its sequence number.
//
// Every failure is a *RejectError carrying both a machine-readable reason and
// the disposition the protocol assigns it. Validation that needs world
// knowledge (bounds, reachability) is not done here.
//
// A seq the envelope accepted comes back even when the body is then refused,
// because it is consumed either way: last_seq must not depend on whether the
// server liked the body (PROTOCOL.md, "Sequence numbers").
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
		// Not a compatibility question: a frame that names zero messages or two
		// cannot be interpreted at all.
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
		default:
			// Logged loudly and ignored, and refused before the seq is looked
			// at: a message this server cannot interpret has no sequence number
			// it may consume. A peer written against a later protocol version
			// must not be broken by this one.
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

// decodeSeq reads the sequence number out of an intent body already attributed
// to the message named by re.
//
// Everything but the range is encoding/json's job: a fractional, quoted,
// boolean or int64-overflowing seq fails to unmarshal into *int64 and lands
// here as a malformed frame. Absent stays absent, and 0 is refused rather than
// read as absent, because a client that computed a sequence number and got zero
// has a bug the server should name (PROTOCOL.md, "Sequence numbers").
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
	// Deliberately not DisallowUnknownFields: senders may add fields, and seq
	// has already been read off this payload by the envelope (PROTOCOL.md,
	// "Compatibility" rule 2).
	var wire moveToWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectIntent(ReasonMalformedJSON, MsgMoveTo, "move_to: %v", err)
	}
	if wire.X == nil || wire.Z == nil {
		return nil, rejectIntent(ReasonMissingField, MsgMoveTo, "move_to needs both x and z")
	}
	// The finite check runs on the decoded value, not on the source text:
	// whether a huge literal errors or saturates to +Inf differs by parser
	// path, and either way what reaches world state must be a real coordinate.
	if !finite(*wire.X) || !finite(*wire.Z) {
		return nil, rejectIntent(ReasonNonFinite, MsgMoveTo, "move_to coordinates must be finite")
	}
	return MoveTo{X: *wire.X, Z: *wire.Z}, nil
}

// decodePickup parses a pickup body. Whether the named item exists is a
// question about world state and is not asked here; this only establishes that
// the client named one.
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

// decodeDrop parses a drop body. Whether the slot exists and whether it holds
// anything are questions about world state and are not asked here; this only
// establishes that the client named a slot.
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

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }
