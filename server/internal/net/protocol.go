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

// MsgMoveTo is the name of the only client-to-server message in M0. It is the
// key in the envelope and the value of an error's "re" field.
const MsgMoveTo = "move_to"

// PlayerState is one player's position, as it appears inside welcome.
type PlayerState struct {
	ID PlayerID `json:"id"`
	X  float64  `json:"x"`
	Z  float64  `json:"z"`
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
type Welcome struct {
	You     PlayerID      `json:"you"`
	TickMS  int           `json:"tick_ms"`
	Tick    int64         `json:"tick"`
	Players []PlayerState `json:"players"`
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

func (Welcome) isServerMessage() {}
func (Spawn) isServerMessage()   {}
func (Despawn) isServerMessage() {}
func (Path) isServerMessage()    {}
func (Error) isServerMessage()   {}

// ClientMessage is one message a client can send. Clients send intents, never
// facts (CLAUDE.md, "Architecture invariants").
type ClientMessage interface{ isClientMessage() }

// MoveTo is a click on the ground: the player wants to walk to (X, Z).
//
// It is an intent, not a position. The server decides whether the destination
// is legal and what path leads there.
type MoveTo struct {
	X float64 `json:"x"`
	Z float64 `json:"z"`
}

func (MoveTo) isClientMessage() {}

// serverEnvelope is the key-as-tag wrapper. Exactly one field is ever non-nil;
// Encode is the only thing that builds it.
type serverEnvelope struct {
	Welcome *Welcome `json:"welcome,omitempty"`
	Spawn   *Spawn   `json:"spawn,omitempty"`
	Despawn *Despawn `json:"despawn,omitempty"`
	Path    *Path    `json:"path,omitempty"`
	Error   *Error   `json:"error,omitempty"`
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

func rejectMoveTo(reason RejectReason, format string, args ...any) error {
	return &RejectError{
		Reason:      reason,
		Detail:      fmt.Sprintf(format, args...),
		Re:          MsgMoveTo,
		Disposition: ReplyError,
	}
}

// moveToWire decodes move_to with pointer fields so that "absent" and "zero"
// stay distinguishable. encoding/json fills a missing field with the zero
// value, which would silently turn {"move_to":{"x":5}} into a click on the x
// axis; that is a decision, and this is where it is made: absent is rejected.
//
// Unknown fields are not listed and are therefore ignored, which is what lets
// M2 add seq to any intent body without breaking this server.
type moveToWire struct {
	X *float64 `json:"x"`
	Z *float64 `json:"z"`
}

// Decode parses one inbound frame.
//
// Every failure is a *RejectError carrying both a machine-readable reason and
// the disposition the protocol assigns it. Validation that needs world
// knowledge (bounds, reachability) is not done here.
func Decode(frame []byte) (ClientMessage, error) {
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(frame, &keys); err != nil {
		return nil, &RejectError{
			Reason:      ReasonMalformedJSON,
			Detail:      fmt.Sprintf("not a JSON object: %v", err),
			Disposition: ReplyError,
		}
	}
	if len(keys) != 1 {
		// Not a compatibility question: a frame that names zero messages or two
		// cannot be interpreted at all.
		return nil, &RejectError{
			Reason:      ReasonProtocolError,
			Detail:      fmt.Sprintf("expected exactly one message key, got %d", len(keys)),
			Disposition: ReplyErrorAndClose,
		}
	}

	for key, payload := range keys {
		switch key {
		case MsgMoveTo:
			return decodeMoveTo(payload)
		default:
			// Logged loudly and ignored. A peer written against a later
			// protocol version must not be broken by this one.
			return nil, &RejectError{
				Reason:      ReasonUnknownMessage,
				Detail:      fmt.Sprintf("unknown message %q", key),
				Re:          key,
				Disposition: Ignore,
			}
		}
	}
	panic("unreachable: map of length 1 yielded no entries")
}

func decodeMoveTo(payload []byte) (ClientMessage, error) {
	// Deliberately not DisallowUnknownFields: senders may add fields, and M2's
	// seq is already spoken for (PROTOCOL.md, "Compatibility" rule 2).
	var wire moveToWire
	if err := json.Unmarshal(payload, &wire); err != nil {
		return nil, rejectMoveTo(ReasonMalformedJSON, "move_to: %v", err)
	}
	if wire.X == nil || wire.Z == nil {
		return nil, rejectMoveTo(ReasonMissingField, "move_to needs both x and z")
	}
	// The finite check runs on the decoded value, not on the source text:
	// whether a huge literal errors or saturates to +Inf differs by parser
	// path, and either way what reaches world state must be a real coordinate.
	if !finite(*wire.X) || !finite(*wire.Z) {
		return nil, rejectMoveTo(ReasonNonFinite, "move_to coordinates must be finite")
	}
	return MoveTo{X: *wire.X, Z: *wire.Z}, nil
}

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }
