package net_test

import (
	"encoding/json"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestEncodeProducesKeyAsTagEnvelope(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		msg  mnet.ServerMessage
		want string
	}{
		{
			name: "welcome",
			msg: mnet.Welcome{
				You:     1,
				Session: "9f2c1ab7d0e4485fa6c3b81d27e05934",
				LastSeq: 7,
				TickMS:  150,
				Tick:    142,
				Players: []mnet.PlayerState{
					{ID: 1, X: 0, Z: 0},
					{ID: 2, X: 5, Z: 5},
				},
				Items: []mnet.ItemState{{ID: 7, Kind: "acorn", X: 3, Z: -2}},
			},
			want: `{"welcome":{"you":1,"session":"9f2c1ab7d0e4485fa6c3b81d27e05934","last_seq":7,"tick_ms":150,"tick":142,"players":[{"id":1,"x":0,"z":0},{"id":2,"x":5,"z":5}],"items":[{"id":7,"kind":"acorn","x":3,"z":-2}]}}`,
		},
		{
			// An empty world is [] on both arrays, never null and never an
			// absent key. A client should not have to tell three spellings of
			// "nothing there" apart. session is a string and is always present,
			// because every welcome names the identity of the player receiving
			// it; there is no such thing as a welcome without one.
			name: "welcome with an empty world",
			msg: mnet.Welcome{
				You:     1,
				Session: "0123456789abcdef0123456789abcdef",
				TickMS:  150,
				Tick:    0,
				Players: []mnet.PlayerState{},
				Items:   []mnet.ItemState{},
			},
			want: `{"welcome":{"you":1,"session":"0123456789abcdef0123456789abcdef","last_seq":0,"tick_ms":150,"tick":0,"players":[],"items":[]}}`,
		},
		{
			name: "item_spawn",
			msg:  mnet.ItemSpawn{ID: 7, Kind: "acorn", X: 3, Z: -2},
			want: `{"item_spawn":{"id":7,"kind":"acorn","x":3,"z":-2}}`,
		},
		{
			name: "item_despawn",
			msg:  mnet.ItemDespawn{ID: 7},
			want: `{"item_despawn":{"id":7}}`,
		},
		{
			name: "inventory",
			msg:  mnet.Inventory{Size: 28, Slots: []mnet.InventorySlot{{Slot: 1, Kind: "acorn"}}},
			want: `{"inventory":{"size":28,"slots":[{"slot":1,"kind":"acorn"}]}}`,
		},
		{
			name: "empty inventory",
			msg:  mnet.Inventory{Size: 28, Slots: []mnet.InventorySlot{}},
			want: `{"inventory":{"size":28,"slots":[]}}`,
		},
		{
			name: "spawn",
			msg:  mnet.Spawn{ID: 2, X: 0, Z: 0},
			want: `{"spawn":{"id":2,"x":0,"z":0}}`,
		},
		{
			name: "despawn",
			msg:  mnet.Despawn{ID: 2},
			want: `{"despawn":{"id":2}}`,
		},
		{
			name: "path",
			msg: mnet.Path{
				ID:        1,
				StartTick: 142,
				Points:    []mnet.Point{mnet.Pt(10, 4), mnet.Pt(42.3, 17.8)},
				Speed:     3,
			},
			want: `{"path":{"id":1,"start_tick":142,"points":[[10,4],[42.3,17.8]],"speed":3}}`,
		},
		{
			name: "error",
			msg:  mnet.Error{Re: "move_to", Msg: "out of bounds"},
			want: `{"error":{"re":"move_to","msg":"out of bounds"}}`,
		},
		{
			name: "error with nothing to attribute it to",
			msg:  mnet.Error{Msg: "text frames only"},
			want: `{"error":{"msg":"text frames only"}}`,
		},
		{
			name: "tick",
			msg:  mnet.Tick{T: 10},
			want: `{"tick":{"t":10}}`,
		},
		{
			name: "welcome naming the heartbeat period",
			msg: mnet.Welcome{
				You:            1,
				Session:        "0123456789abcdef0123456789abcdef",
				TickMS:         150,
				Tick:           0,
				HeartbeatTicks: 10,
				Players:        []mnet.PlayerState{},
				Items:          []mnet.ItemState{},
			},
			want: `{"welcome":{"you":1,"session":"0123456789abcdef0123456789abcdef","last_seq":0,"tick_ms":150,"tick":0,"heartbeat_ticks":10,"players":[],"items":[]}}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := mnet.Encode(tc.msg)
			if err != nil {
				t.Fatalf("Encode(%T) failed: %v", tc.msg, err)
			}
			if string(got) != tc.want {
				t.Fatalf("Encode(%T)\n got: %s\nwant: %s", tc.msg, got, tc.want)
			}
			assertExactlyOneKey(t, got)
		})
	}
}

func assertExactlyOneKey(t *testing.T, frame []byte) {
	t.Helper()
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(frame, &keys); err != nil {
		t.Fatalf("frame is not a JSON object: %s: %v", frame, err)
	}
	if len(keys) != 1 {
		t.Fatalf("frame has %d keys, want exactly 1: %s", len(keys), frame)
	}
}

func TestDecodeMoveTo(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name    string
		frame   string
		wantSeq mnet.Seq
	}{
		{"plain", `{"move_to":{"x":42.3,"z":17.8}}`, 0},
		{"with a seq", `{"move_to":{"x":42.3,"z":17.8,"seq":9}}`, 9},
		// The high-water mark is unbounded, so the largest number the wire type
		// can carry has to survive the round trip rather than overflow into a
		// refusal or a negative.
		{"with the largest seq an int64 holds", `{"move_to":{"x":42.3,"z":17.8,"seq":9223372036854775807}}`, 9223372036854775807},
		{"with an explicitly null seq", `{"move_to":{"x":42.3,"z":17.8,"seq":null}}`, 0},
		// Compatibility rule 2: senders may add fields.
		{"with a field nobody has invented yet", `{"move_to":{"x":42.3,"z":17.8,"whatever":true}}`, 0},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, seq, err := mnet.Decode([]byte(tc.frame))
			if err != nil {
				t.Fatalf("Decode(%s) failed: %v", tc.frame, err)
			}
			got, ok := msg.(mnet.MoveTo)
			if !ok {
				t.Fatalf("Decode returned %T, want MoveTo", msg)
			}
			if got.X != 42.3 || got.Z != 17.8 {
				t.Fatalf("Decode gave %+v, want {X:42.3 Z:17.8}", got)
			}
			if seq != tc.wantSeq {
				t.Fatalf("Decode(%s) gave seq %d, want %d", tc.frame, seq, tc.wantSeq)
			}
		})
	}
}

// TestDecodeNamesEveryMessageAfterItsWireKey pins the pairing Event.Name and
// every "re" field rest on. A message whose Name disagreed with the key it
// decoded from would file its duplicates under another message's name.
func TestDecodeNamesEveryMessageAfterItsWireKey(t *testing.T) {
	t.Parallel()

	cases := []struct{ key, frame string }{
		{mnet.MsgMoveTo, `{"move_to":{"x":1,"z":2}}`},
		{mnet.MsgPickup, `{"pickup":{"item":7}}`},
		{mnet.MsgDrop, `{"drop":{"slot":3}}`},
	}

	for _, tc := range cases {
		t.Run(tc.key, func(t *testing.T) {
			t.Parallel()
			msg, _, err := mnet.Decode([]byte(tc.frame))
			if err != nil {
				t.Fatalf("Decode(%s) failed: %v", tc.frame, err)
			}
			if got := msg.Name(); got != tc.key {
				t.Fatalf("Decode(%s) returned a %T naming itself %q, want %q", tc.frame, msg, got, tc.key)
			}
		})
	}
}

// TestABodyRejectionStillReportsItsSequenceNumber is the one place a seq and an
// error come back together. A seq the envelope accepted is consumed even when
// the body is then refused, so dropping it here would make last_seq depend on
// whether the server liked the body (PROTOCOL.md, "Sequence numbers").
func TestABodyRejectionStillReportsItsSequenceNumber(t *testing.T) {
	t.Parallel()

	const frame = `{"move_to":{"x":1,"seq":5}}`

	msg, seq, err := mnet.Decode([]byte(frame))
	if err == nil {
		t.Fatalf("Decode(%s) accepted the frame as %#v, want a missing-field rejection", frame, msg)
	}
	rejection, ok := mnet.Rejection(err)
	if !ok {
		t.Fatalf("Decode(%s) returned %v, which is not a rejection", frame, err)
	}
	if rejection.Reason != mnet.ReasonMissingField {
		t.Fatalf("Decode(%s) rejected with %q, want %q", frame, rejection.Reason, mnet.ReasonMissingField)
	}
	if seq != 5 {
		t.Fatalf("Decode(%s) gave seq %d alongside the refusal, want 5: the envelope accepted that number and the sender has spent it",
			frame, seq)
	}
}

func TestDecodeRejections(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name       string
		frame      string
		wantReason mnet.RejectReason
		wantWhat   mnet.Disposition
		wantRe     string
	}{
		{"not json", `hello`, mnet.ReasonMalformedJSON, mnet.ReplyError, ""},
		{"not an object", `[1,2,3]`, mnet.ReasonMalformedJSON, mnet.ReplyError, ""},
		// Zero or two keys is a malformed frame, not a compatibility question:
		// there is no message to interpret.
		{"empty object", `{}`, mnet.ReasonProtocolError, mnet.ReplyErrorAndClose, ""},
		{"two keys", `{"move_to":{"x":1,"z":2},"use":{}}`, mnet.ReasonProtocolError, mnet.ReplyErrorAndClose, ""},
		// Compatibility rule 1: one unknown key is logged and ignored, so a
		// client written against a later protocol keeps working.
		{"unknown message", `{"teleport":{"x":1,"z":2}}`, mnet.ReasonUnknownMessage, mnet.Ignore, "teleport"},
		// A field left out is a broken client, not a click on an axis.
		// encoding/json would otherwise fill z with 0 and the server would
		// happily walk the player to it.
		{"missing z", `{"move_to":{"x":5}}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"missing x", `{"move_to":{"z":5}}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"null payload", `{"move_to":null}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"wrong type", `{"move_to":{"x":"far","z":2}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		// JSON has no literal for NaN or infinity, so a client trying to send
		// one is refused while still text. The finite check in Decode runs on
		// the decoded float and is the backstop for any parser that saturates
		// an overflowing literal instead of failing on it.
		// NaN is invalid JSON anywhere in the document, so the frame fails
		// before the key is read and there is no message to attribute it to.
		{"nan literal", `{"move_to":{"x":NaN,"z":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, ""},
		{"overflowing literal", `{"move_to":{"x":1e400,"z":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"zero seq", `{"move_to":{"x":1,"z":1,"seq":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"negative seq", `{"move_to":{"x":1,"z":1,"seq":-1}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"fractional seq", `{"move_to":{"x":1,"z":1,"seq":1.5}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"quoted seq", `{"move_to":{"x":1,"z":1,"seq":"7"}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"seq past what an int64 holds", `{"move_to":{"x":1,"z":1,"seq":9223372036854775808}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		// The seq is refused before the body is looked at, so a frame that is
		// wrong in both ways is answered for the seq. Ordering, not preference:
		// the envelope is read first.
		{"a bad seq on a body that is also broken", `{"move_to":{"x":1,"seq":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		// An unknown message never reaches the seq parse: there is nothing to
		// spend a sequence number on, and the frame is ignored rather than
		// answered.
		{"a bad seq on an unknown message", `{"teleport":{"seq":0}}`, mnet.ReasonUnknownMessage, mnet.Ignore, "teleport"},
		{"a bad seq on a pickup", `{"pickup":{"item":7,"seq":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "pickup"},
		{"a bad seq on a drop", `{"drop":{"slot":3,"seq":"7"}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "drop"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, _, err := mnet.Decode([]byte(tc.frame))
			if err == nil {
				t.Fatalf("Decode(%s) accepted the frame as %#v, want rejection %q", tc.frame, msg, tc.wantReason)
			}
			rejection, ok := mnet.Rejection(err)
			if !ok {
				t.Fatalf("Decode(%s) returned %v, which is not a rejection", tc.frame, err)
			}
			if rejection.Reason != tc.wantReason {
				t.Fatalf("Decode(%s) rejected with %q, want %q (%v)", tc.frame, rejection.Reason, tc.wantReason, err)
			}
			if rejection.Disposition != tc.wantWhat {
				t.Fatalf("Decode(%s) disposition %v, want %v", tc.frame, rejection.Disposition, tc.wantWhat)
			}
			if rejection.Re != tc.wantRe {
				t.Fatalf("Decode(%s) attributed to %q, want %q", tc.frame, rejection.Re, tc.wantRe)
			}
			if rejection.Detail == "" {
				t.Fatalf("Decode(%s) gave no human detail to put in an error message", tc.frame)
			}
		})
	}
}

// TestLargeFiniteCoordinateDecodesCleanly pins the hazard the protocol calls
// out: 1e30 is not a decoder problem, it is a bounds problem, and the decoder
// must hand it on rather than refuse it.
func TestLargeFiniteCoordinateDecodesCleanly(t *testing.T) {
	t.Parallel()

	msg, _, err := mnet.Decode([]byte(`{"move_to":{"x":1e30,"z":0}}`))
	if err != nil {
		t.Fatalf("Decode rejected a finite coordinate: %v", err)
	}
	if got := msg.(mnet.MoveTo); got.X != 1e30 {
		t.Fatalf("decoded x=%v, want 1e30", got.X)
	}
}
